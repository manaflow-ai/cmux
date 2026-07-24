import CmuxSimulator
import Foundation
import Observation

/// Main-actor state and ordered command routing for one Simulator pane.
@MainActor
@Observable
public final class SimulatorPaneCoordinator {
    static let maximumOutgoingMessageCount = 128
    static let maximumActionLogCount = 500
    /// Installed iPhone and iPad Simulator devices.
    public internal(set) var devices: [SimulatorDevice] = []
    /// The selected CoreSimulator device identifier.
    public internal(set) var selectedDeviceID: String?
    /// The isolated worker session state.
    public internal(set) var status: SimulatorSessionStatus = .idle
    /// Capabilities negotiated with the selected Xcode and runtime.
    public internal(set) var capabilities: Set<SimulatorCapability> = []
    /// Live framebuffer metadata.
    public internal(set) var display: SimulatorDisplayMetadata?
    /// Read-only packed-frame shared memory published by the isolated worker.
    public internal(set) var frameTransport: SimulatorFrameTransportDescriptor?
    /// The latest recoverable or terminal failure.
    public internal(set) var failure: SimulatorFailure?
    /// The current foreground application, when inspection is supported.
    public internal(set) var foregroundApplication: SimulatorApplicationInfo?
    /// The latest accessibility snapshot, when inspection is supported.
    public internal(set) var accessibilitySnapshot: SimulatorAccessibilitySnapshot?
    /// A bounded, depth-first presentation cache rebuilt only on snapshot receipt.
    var accessibilityRows: [SimulatorAccessibilityPresentationRow] = []
    /// Recent worker and control actions, newest first.
    public internal(set) var actionLog: [SimulatorActionLogEntry] = []
    /// Applications installed on the selected Simulator.
    public internal(set) var installedApplications: [SimulatorInstalledApplication] = []
    /// User-installed applications safe for targeted camera injection.
    public internal(set) var userInstalledApplications: [SimulatorInstalledApplication] = []
    /// Plain text read from the simulated pasteboard.
    public internal(set) var clipboardText = ""
    /// The most recently requested bounded unified log output.
    public internal(set) var recentLogsText = ""
    /// Live unified log output, bounded to protect the host process.
    public internal(set) var liveLogsText = ""
    /// The latest control-surface failure.
    public internal(set) var controlFailure: SimulatorFailure?
    /// Whether at least one one-shot control action is running.
    public internal(set) var isPerformingControlAction = false
    /// Whether a `simctl io recordVideo` child is active.
    public internal(set) var isVideoRecording = false
    /// Whether a live Simulator unified-log child is active.
    public internal(set) var isStreamingLogs = false
    /// The active experimental camera source.
    public internal(set) var cameraConfiguration: SimulatorCameraConfiguration = .disabled
    /// The latest correlated camera adapter status.
    public internal(set) var cameraStatus: SimulatorCameraStatus?
    /// The latest live private appearance and accessibility status.
    public internal(set) var interfaceStatus: SimulatorInterfaceStatus?
    /// The latest correlated permission readback.
    public internal(set) var privacySnapshot: SimulatorPrivacySnapshot?
    /// The accessibility node currently highlighted over the framebuffer.
    public internal(set) var highlightedAccessibilityNodeID: String?
    /// Whether every current accessibility frame is drawn over the live device.
    public internal(set) var accessibilityOverlayEnabled = false
    /// The accessibility element selected inside the host-rendered live overlay.
    public internal(set) var accessibilityOverlaySelectedNodeID: String?
    /// Safari and `WKWebView` pages exposed by the selected Simulator.
    public internal(set) var webInspectorTargets: [SimulatorWebInspectorTarget] = []
    /// The worker-owned raw Web Inspector session.
    public internal(set) var webInspectorSession: SimulatorWebInspectorSessionStatus = .detached
    /// Bounded complete raw responses, newest first.
    var webInspectorResponses: [SimulatorWebInspectorResponse] = []
    /// Whether the selected inspector page is currently highlighted.
    public internal(set) var webInspectorIsHighlighted = false
    /// Whether a cmux-managed simulated location route is active.
    public internal(set) var locationRouteIsActive = false
    /// Whether the active simulated location route is paused.
    public internal(set) var locationRouteIsPaused = false
    var chromeProfile: SimulatorDeviceChromeProfile?
    /// Whether the native tools inspector is visible.
    public var showsTools = false {
        didSet { setLiveStatusVisibility(effectivePaneIsVisible && showsTools) }
    }
    /// A monotonically increasing request observed by the AppKit input surface.
    public internal(set) var focusRequestGeneration: UInt64 = 0
    /// Input currently captured by SimulatorKit inside the worker.
    public internal(set) var hidCaptureMode: SimulatorHIDCaptureMode = .none

    /// The selected device snapshot used by panel persistence.
    public var selectedDevice: SimulatorDevice? {
        devices.first(where: { $0.id == selectedDeviceID })
    }

    @ObservationIgnored let client: any SimulatorPaneClient
    @ObservationIgnored let filePicker: any SimulatorFilePicking
    @ObservationIgnored let webInspectorSleeper: any SimulatorProcessSleeper
    @ObservationIgnored let preferredDeviceID: String?
    @ObservationIgnored let preferredRuntimeIdentifier: String?
    @ObservationIgnored let preferredDeviceTypeIdentifier: String?
    @ObservationIgnored public internal(set) var requiresExplicitDeviceSelection: Bool
    @ObservationIgnored var outgoingStream: AsyncStream<SimulatorWorkerInbound>
    @ObservationIgnored var outgoingContinuation: AsyncStream<SimulatorWorkerInbound>.Continuation
    @ObservationIgnored var outgoingTask: Task<Void, Never>?
    @ObservationIgnored var outgoingRecoveryTask: Task<Void, Never>?
    @ObservationIgnored var outgoingRecoveryGeneration: UInt64 = 0
    @ObservationIgnored var outgoingOverflowed = false
    @ObservationIgnored var eventsTask: Task<Void, Never>?
    @ObservationIgnored var activationTask: Task<Void, Never>?
    @ObservationIgnored var startupTask: Task<Void, Never>?
    @ObservationIgnored var started = false
    @ObservationIgnored var closed = false
    @ObservationIgnored var geometry: SimulatorSurfaceGeometry?
    @ObservationIgnored var selectionGeneration: UInt64 = 0
    @ObservationIgnored var explicitSelectionRequestGeneration: UInt64 = 0
    @ObservationIgnored var deviceDiscoveryGeneration: UInt64 = 0
    @ObservationIgnored var activeControlActions = 0
    @ObservationIgnored var controlActionTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var controlActionTaskTokens: [String: UUID] = [:]
    @ObservationIgnored var actionHistoryByDeviceID: [String: [SimulatorActionLogEntry]] = [:]
    @ObservationIgnored var videoSession: SimulatorProcessSession?
    @ObservationIgnored var logSession: SimulatorProcessSession?
    @ObservationIgnored let liveLogBuffer = SimulatorLiveLogBuffer()
    @ObservationIgnored let chromeLoader = SimulatorDeviceChromeLoader()
    @ObservationIgnored var chromeTask: Task<Void, Never>?
    @ObservationIgnored var webInspectorResponseBuffer = SimulatorWebInspectorResponseBuffer()
    @ObservationIgnored var textInputCompletions: [UUID: @MainActor @Sendable (Bool) -> Void] = [:]
    @ObservationIgnored var cancelledTextInputRequestIDs: Set<UUID> = []
    @ObservationIgnored var pendingWebInspectorResponses: [
        SimulatorWebInspectorJSONRequestID: SimulatorPendingWebInspectorResponse
    ] = [:]
    @ObservationIgnored var retiredWebInspectorRequestIDs: Set<SimulatorWebInspectorJSONRequestID> = []
    @ObservationIgnored var accessibilityRefreshTask: Task<Void, Never>?
    @ObservationIgnored var accessibilityRefreshGeneration: UInt64 = 0
    @ObservationIgnored var accessibilityOverlayIsVisible = false
    @ObservationIgnored var liveStatusTask: Task<Void, Never>?
    @ObservationIgnored var liveStatusGeneration: UInt64 = 0
    @ObservationIgnored var liveStatusIsVisible = false
    @ObservationIgnored var liveStatusPollingActive = false
    @ObservationIgnored var capabilityHydrationCompleted = false
    @ObservationIgnored var capabilityHydrationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored var paneIsVisible = false
    @ObservationIgnored var hostWindowIsVisible = true
    @ObservationIgnored var hostWindowVisibilityByObserverID: [UUID: Bool] = [:]
    @ObservationIgnored let legacyHostWindowVisibilityObserverID = UUID()
    @ObservationIgnored var frameIsVisible = false
    @ObservationIgnored var locationRouteDeviceID: String?
    @ObservationIgnored var locationRoute: SimulatorLocationRoute?
    @ObservationIgnored var locationRouteRemainingDuration: TimeInterval?
    @ObservationIgnored var locationRouteStartedAt: Date?
    @ObservationIgnored var locationRouteGeneration: UInt64 = 0
    @ObservationIgnored var locationRouteCompletionTask: Task<Void, Never>?
    @ObservationIgnored var locationRouteTeardownTask: Task<Void, Never>?
    @ObservationIgnored let locationRouteSleeper: any SimulatorProcessSleeper
    @ObservationIgnored let locationRouteNow: @Sendable () -> Date

    /// Creates state for a pane backed by an injected Simulator client.
    /// - Parameters:
    ///   - client: The process-safe Simulator client implementation.
    ///   - preferredDeviceID: The persisted device identifier to restore first.
    ///   - preferredRuntimeIdentifier: Persisted runtime metadata for the selected device.
    ///   - preferredDeviceTypeIdentifier: Persisted hardware-type metadata for the selected device.
    ///   - filePicker: The native file-selection dependency.
    public convenience init(
        client: any SimulatorPaneClient,
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        requiresExplicitDeviceSelection: Bool = false,
        filePicker: any SimulatorFilePicking = NativeSimulatorFilePicker()
    ) {
        self.init(
            client: client,
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier,
            requiresExplicitDeviceSelection: requiresExplicitDeviceSelection,
            filePicker: filePicker,
            webInspectorSleeper: ContinuousSimulatorProcessSleeper(),
            locationRouteSleeper: ContinuousSimulatorProcessSleeper()
        )
    }

    init(
        client: any SimulatorPaneClient,
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        requiresExplicitDeviceSelection: Bool = false,
        filePicker: any SimulatorFilePicking = NativeSimulatorFilePicker(),
        webInspectorSleeper: any SimulatorProcessSleeper,
        locationRouteSleeper: any SimulatorProcessSleeper = ContinuousSimulatorProcessSleeper(),
        locationRouteNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.filePicker = filePicker
        self.webInspectorSleeper = webInspectorSleeper
        self.locationRouteSleeper = locationRouteSleeper
        self.locationRouteNow = locationRouteNow
        self.preferredDeviceID = preferredDeviceID
        self.preferredRuntimeIdentifier = preferredRuntimeIdentifier
        self.preferredDeviceTypeIdentifier = preferredDeviceTypeIdentifier
        self.requiresExplicitDeviceSelection = requiresExplicitDeviceSelection
        let (stream, continuation) = AsyncStream.makeStream(
            of: SimulatorWorkerInbound.self,
            bufferingPolicy: .bufferingOldest(Self.maximumOutgoingMessageCount)
        )
        self.outgoingStream = stream
        self.outgoingContinuation = continuation
        self.frameTransport = nil
    }

    deinit {
        activationTask?.cancel()
        startupTask?.cancel()
        chromeTask?.cancel()
        accessibilityRefreshTask?.cancel()
        liveStatusTask?.cancel()
        locationRouteCompletionTask?.cancel()
        locationRouteTeardownTask?.cancel()
        eventsTask?.cancel()
        outgoingTask?.cancel()
        outgoingContinuation.finish()
        for pending in pendingWebInspectorResponses.values {
            pending.timeoutTask.cancel()
        }
    }

}

func simulatorPaneFailure(from error: any Error, code: String) -> SimulatorFailure {
    if let failure = error as? SimulatorFailure { return failure }
    return SimulatorFailure(code: code, message: String(describing: error), isRecoverable: true)
}
