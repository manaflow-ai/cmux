import AppKit
import CmuxControlSocket
import CmuxSimulator
import Darwin
import Foundation
import Security

enum ComputerUseDirectScreenCaptureVerification: Equatable, Sendable {
    case ready
    case notCapturable
    case unavailable
}

/// The single app-side owner of the standalone Computer Use helper lifecycle.
///
/// The main cmux process never calls TCC-protected APIs and never executes the
/// driver binary. It installs the helper, launches that app through
/// LaunchServices, and reads permission status exclusively over the daemon UDS.
@MainActor
final class ComputerUseRuntimeService: ApplicationSurfaceRuntime {
    static let helperAppName = "cmux Computer Use"
    nonisolated private static let helperExecutableName = "cmux Computer Use"
    nonisolated private static let maximumApplicationWindowDimension =
        1_000_000.0

    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    let paths: ComputerUseRuntimePaths
    let applicationName: String
    let stateAuthenticationKey: Data

    private let bundledHelperAppURL: URL?
    private let transport: SocketTransport
    private let applicationSurfaceInputConnections:
        ApplicationSurfaceInputConnectionRegistry
    private let applicationSurfaceFailureEventRegistry =
        ApplicationSurfaceFailureEventRegistry()
    private var installedHelperURL: URL?
    private var helperLifecycleTask: Task<Void, Never>?
    private var helperLifecycleCancellationActions: [Int: @Sendable () -> Void] = [:]
    private var helperLifecycleGeneration = 0
    private var helperTerminationObservationTask: Task<Void, Never>?
    private var helperHealthTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var finalHelperCleanupTask: Task<Void, Never>?
    private var finalHelperCleanupGeneration = UUID()
    private var finalHelperCleanupState =
        ComputerUseFinalHelperCleanupState.idle
    private var cachedStatus = ComputerUsePermissionStatus.unknown
    private var permissionRefreshGeneration = 0
    private(set) var permissionPhase =
        ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false)
    private var readinessPublicationTask: Task<Void, Never>?
    private var readinessPublicationGeneration = 0
    private var acceptsNewLaunches = true
    private var computerUseEnabled = false
    private var applicationSurfaceLeaseIdentifiers: Set<UUID> = []
    private var applicationSurfaceSessionIDsByLease: [UUID: Set<String>] = [:]
    private var applicationSurfacePendingStops:
        [String: ApplicationSurfacePendingStop] = [:]
    private var runningHelperProcesses:
        [ComputerUseDaemonProfile: AgentPIDProcessIdentity] = [:]
    private var missedHelperHealthChecks = 0
    private var expectedTerminationProcessIdentifiers: Set<pid_t> = []

    private var desiredEnabled: Bool {
        computerUseEnabled || !applicationSurfaceLeaseIdentifiers.isEmpty
    }

    init(
        bundle: Bundle = .main,
        paths: ComputerUseRuntimePaths = ComputerUseRuntimePaths(),
        transport: SocketTransport = SocketTransport()
    ) {
        self.paths = paths
        self.transport = transport
        applicationSurfaceInputConnections =
            ApplicationSurfaceInputConnectionRegistry(transport: transport)
        stateAuthenticationKey = Self.makeStateAuthenticationKey()
        let nestedURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/\(Self.helperAppName).app", isDirectory: true)
        applicationName = Self.helperAppName
        if FileManager.default.fileExists(atPath: nestedURL.path) {
            bundledHelperAppURL = nestedURL
        } else {
            bundledHelperAppURL = nil
        }
        startObservingHelperTermination()
    }

    deinit {
        for cancel in helperLifecycleCancellationActions.values {
            cancel()
        }
        helperLifecycleTask?.cancel()
        helperTerminationObservationTask?.cancel()
        helperHealthTask?.cancel()
        recoveryTask?.cancel()
        finalHelperCleanupTask?.cancel()
        readinessPublicationTask?.cancel()
    }

    var helperAppURL: URL? {
        installedHelperURL
    }

    /// The branded helper icon used while its top-level copy is still installing.
    ///
    /// Keep `helperAppURL` restricted to the installed helper because permission
    /// interactions need that independently registered URL. Presentation can use
    /// the identical nested app immediately, avoiding a generic first frame.
    var presentationIcon: NSImage? {
        let candidate = installedHelperURL ?? bundledHelperAppURL
        return Self.resolvePresentationIcon(helperAppURL: candidate)
    }

    static func resolvePresentationIcon(
        helperAppURL: URL?,
        loadArtwork: (URL) -> NSImage? = { NSImage(contentsOf: $0) },
        loadFallbackIcon: (URL) -> NSImage? = {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
    ) -> NSImage? {
        guard let helperAppURL else { return nil }
        let iconURL = helperAppURL
            .appendingPathComponent("Contents/Resources/AppIcon.icns", isDirectory: false)
        if let icon = loadArtwork(iconURL) {
            return icon
        }
        return loadFallbackIcon(helperAppURL)
    }

    var stateDirectoryURL: URL {
        paths.stateDirectoryURL
    }

    func status() -> (accessibility: Bool, screenRecording: Bool) {
        (cachedStatus.accessibility, cachedStatus.screenRecording)
    }

    var permissionStatusIsKnown: Bool {
        cachedStatus.isKnown
    }

    /// Seeds the host gate from the capture verification persisted by the last
    /// completed onboarding run. This is called before the enabled setting is
    /// reconciled, so starting the helper can publish the correct first value.
    func setInitialOnboardingCompletion(_ completed: Bool) {
        guard !desiredEnabled else { return }
        permissionPhase = .disabled(onboardingComplete: completed)
    }

    func onboardingWasPresented() {
        transitionPermissionPhase(.onboardingPresented)
    }

    func onboardingWasCompleted() {
        transitionPermissionPhase(.onboardingCompleted)
    }

    /// Emits coalesced filesystem changes from the user's TCC database.
    ///
    /// The event is only a refresh trigger; the helper remains the sole
    /// authority for whether either permission is actually granted.
    nonisolated func permissionStatusEvents() -> AsyncStream<Void> {
        let directoryURL = paths.permissionDatabaseDirectoryURL
        return Self.mergedFileSystemEvents(at: [
            directoryURL,
            directoryURL.appendingPathComponent("TCC.db"),
        ], fallbackInterval: .milliseconds(500))
    }

    /// Reconciles the helper daemon with the live `computerUse.enabled` setting.
    func setEnabled(_ newValue: Bool) async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        permissionRefreshGeneration &+= 1
        permissionPhase = permissionPhase.applying(.setEnabled(newValue))
        computerUseEnabled = newValue
        if desiredEnabled {
            cancelFinalHelperCleanup()
            await startIfNeeded()
            startMonitoringHelperHealth()
        } else {
            cancelReadinessPublication()
            await stopHelperAfterLastDemand()
        }
    }

    /// Installs the nested helper at its independently registered top-level URL.
    @discardableResult
    func ensureStandaloneHelperInstalled() async -> URL? {
        await serializeHelperLifecycle(cancelledResult: nil as URL?) { [weak self] in
            guard let self else { return nil }
            return await self.ensureStandaloneHelperInstalledWithinLifecycle()
        }
    }

    /// Passively reads fresh TCC status from an already-running helper.
    ///
    /// Settings and onboarding call this while rendering and after returning
    /// from System Settings. It must never install, start, stop, or restart the
    /// helper: opening Settings is not authorization to override the enabled
    /// preference or interrupt an active Computer Use request.
    @discardableResult
    func refreshHelperStatus() async -> (accessibility: Bool, screenRecording: Bool) {
        guard acceptsNewLaunches, !Task.isCancelled else { return status() }
        permissionRefreshGeneration &+= 1
        let generation = permissionRefreshGeneration
        let enabledAtStart = desiredEnabled
        let paths = self.paths
        let transport = self.transport

        // TCC's "Quit & Reopen" briefly replaces the helper with a process that
        // has not yet rebound cmux's serve socket. Waiting belongs outside the
        // helper-lifecycle chain: recovery needs that same chain to terminate
        // the transient process and launch the correctly configured daemon.
        let latest = enabledAtStart
            ? await Self.waitForPermissionStatus(
                paths: paths,
                transport: transport
            )
            : await Self.queryPermissionStatus(
                paths: paths,
                transport: transport
            )
        guard
            !Task.isCancelled,
            acceptsNewLaunches,
            generation == permissionRefreshGeneration,
            desiredEnabled == enabledAtStart
        else {
            return status()
        }
        cachedStatus = cachedStatus.applyingProbeResult(latest)
        return status()
    }

    /// Reconciles the helper immediately after a known TCC mutation, then reads
    /// status from that recovered generation.
    ///
    /// A drag into System Settings can terminate both helper profiles. Waiting
    /// for two periodic health misses adds several seconds before recovery even
    /// starts, so onboarding uses this explicit path for its drag and TCC-event
    /// callbacks. Other passive status reads remain lifecycle-neutral.
    @discardableResult
    func refreshHelperStatusAfterPermissionChange() async
        -> (accessibility: Bool, screenRecording: Bool)
    {
        guard acceptsNewLaunches, !Task.isCancelled else { return status() }
        permissionRefreshGeneration &+= 1
        guard desiredEnabled else {
            return await refreshHelperStatus()
        }
        missedHelperHealthChecks = 0
        let recovery = scheduleHelperRecovery()
        await recovery?.value
        guard
            acceptsNewLaunches,
            desiredEnabled,
            !Task.isCancelled
        else {
            return status()
        }
        return await refreshHelperStatus()
    }

    func revealHelperInFinder() {
        Task { @MainActor [weak self] in
            guard let self, let url = await ensureStandaloneHelperInstalled() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openAccessibilitySettings() async -> Bool {
        await openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func openScreenRecordingSettings() async -> Bool {
        await openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    /// Asks the exact cmux-managed native helper generation to raise one native
    /// macOS permission prompt.
    ///
    /// This uses the helper's host-only daemon method. It is deliberately not
    /// part of the MCP or CLI tool registry, so an agent cannot bypass cmux's
    /// explicit onboarding UI.
    func requestSystemPermission(
        _ permission: ComputerUseSystemPermission
    ) async -> ComputerUsePermissionRequestOutcome {
        await serializeHelperLifecycle(cancelledResult: .unknown) { [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                !Task.isCancelled
            else {
                return .unknown
            }
            await self.startIfNeededWithinLifecycle()
            guard
                !Task.isCancelled,
                let expectedPeerIdentity = self.processIdentity(for: .native),
                AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                    == expectedPeerIdentity
            else {
                return .unknown
            }
            return await Self.requestSystemPermission(
                permission,
                paths: self.paths,
                transport: self.transport,
                expectedPeerIdentity: expectedPeerIdentity
            )
        }
    }

    /// Socket-level host request kept internal so the app test target can prove
    /// the normal bearer token, host capability, request shape, and peer
    /// generation validation together.
    nonisolated static func requestSystemPermission(
        _ permission: ComputerUseSystemPermission,
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentity: AgentPIDProcessIdentity
    ) async -> ComputerUsePermissionRequestOutcome {
        guard
            let response = await sendDaemonRequest(
                [
                    "method": "request_system_permission",
                    "name": permission.rawValue,
                ],
                paths: paths,
                transport: transport,
                timeout: 3,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: paths.daemonSocketURL
            )
        else {
            return .unknown
        }
        guard response["ok"] as? Bool == true else {
            return .rejected
        }
        guard
            let result = response["result"] as? [String: Any],
            result["requested"] as? Bool == true,
            result["permission"] as? String == permission.rawValue
        else {
            return .unknown
        }
        return .accepted
    }

    func acquireApplicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease? {
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        let identifier = UUID()
        applicationSurfaceLeaseIdentifiers.insert(identifier)
        applicationSurfaceSessionIDsByLease[identifier] = []
        cancelFinalHelperCleanup()
        permissionRefreshGeneration &+= 1
        await startIfNeeded()
        startMonitoringHelperHealth()
        guard
            applicationSurfaceLeaseIdentifiers.contains(identifier),
            let identity = processIdentity(for: .native),
            AgentPIDProcessIdentity(pid: identity.pid) == identity
        else {
            applicationSurfaceLeaseIdentifiers.remove(identifier)
            applicationSurfaceSessionIDsByLease.removeValue(forKey: identifier)
            await stopHelperAfterLastDemand()
            return nil
        }
        return ApplicationSurfaceRuntimeLease(service: self, identifier: identifier)
    }

    func releaseApplicationSurfaceLease(_ identifier: UUID) async {
        guard applicationSurfaceLeaseIdentifiers.contains(identifier) else { return }
        let sessionIDs = applicationSurfaceSessionIDsByLease[identifier] ?? []
        if let identity = processIdentity(for: .native),
           AgentPIDProcessIdentity(pid: identity.pid) == identity {
            for sessionID in sessionIDs {
                let connection =
                    applicationSurfaceInputConnections.connection(
                        for: sessionID
                    )
                let response = await requestApplicationSurfaceStop(
                    sessionID: sessionID,
                    expectedPeerIdentity: identity,
                    persistentConnection: connection
                )
                if Self.applicationSurfaceStopWasAcknowledged(response) {
                    applicationSurfacePendingStops.removeValue(forKey: sessionID)
                } else {
                    recordPendingApplicationSurfaceStop(
                        sessionID: sessionID,
                        helperIdentity: identity
                    )
                }
            }
        }
        for sessionID in sessionIDs {
            applicationSurfaceInputConnections.removeConnection(for: sessionID)
            applicationSurfaceFailureEventRegistry.finish(sessionID: sessionID)
        }
        applicationSurfaceSessionIDsByLease.removeValue(forKey: identifier)
        applicationSurfaceLeaseIdentifiers.remove(identifier)
        permissionRefreshGeneration &+= 1
        await stopHelperAfterLastDemand()
    }

    func listApplicationWindows(
        lease: ApplicationSurfaceRuntimeLease
    ) async throws -> [ApplicationWindowDescriptor] {
        let identity = try validatedApplicationSurfaceIdentity(lease: lease)
        guard let response = await Self.sendDaemonRequest(
            ["method": "application_windows"],
            paths: paths,
            transport: transport,
            timeout: 8,
            expectedPeerIdentity: identity,
            socketURL: paths.daemonSocketURL
        ) else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        try Self.throwApplicationSurfaceResponseError(response)
        guard
            let result = response["result"] as? [String: Any],
            let rawWindows = result["windows"] as? [[String: Any]]
        else {
            throw ApplicationSurfaceRuntimeError.invalidResponse
        }
        return rawWindows.compactMap(Self.applicationWindowDescriptor)
    }

    func startApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        windowID: UInt32,
        processID: Int32,
        frameRate: Int
    ) async throws -> ApplicationSurfaceSessionDescriptor {
        guard (1...120).contains(frameRate), windowID > 0, processID > 0 else {
            throw ApplicationSurfaceRuntimeError.windowUnavailable
        }
        let identity = try validatedApplicationSurfaceIdentity(lease: lease)
        let connection = applicationSurfaceInputConnections.makeConnection()
        guard let response = await Self.sendDaemonRequest(
            [
                "method": "application_surface_start",
                "args": [
                    "window_id": Int(windowID),
                    "process_id": Int(processID),
                    "frame_rate": frameRate,
                ],
            ],
            paths: paths,
            transport: transport,
            timeout: 8,
            expectedPeerIdentity: identity,
            socketURL: paths.daemonSocketURL,
            persistentConnection: connection
        ) else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        try Self.throwApplicationSurfaceResponseError(response)
        guard let result = response["result"] as? [String: Any] else {
            throw ApplicationSurfaceRuntimeError.invalidResponse
        }
        let parsed = Self.parseApplicationSurfaceStartResult(result)
        guard let sessionID = parsed.sessionID else {
            throw ApplicationSurfaceRuntimeError.invalidResponse
        }
        guard let descriptor = parsed.descriptor else {
            let stopResponse = await requestApplicationSurfaceStop(
                sessionID: sessionID,
                expectedPeerIdentity: identity,
                persistentConnection: connection
            )
            if !Self.applicationSurfaceStopWasAcknowledged(stopResponse) {
                recordPendingApplicationSurfaceStop(
                    sessionID: sessionID,
                    helperIdentity: identity
                )
            }
            throw ApplicationSurfaceRuntimeError.invalidResponse
        }
        guard applicationSurfaceLeaseIdentifiers.contains(lease.identifier) else {
            let stopResponse = await requestApplicationSurfaceStop(
                sessionID: sessionID,
                expectedPeerIdentity: identity,
                persistentConnection: connection
            )
            if !Self.applicationSurfaceStopWasAcknowledged(stopResponse) {
                recordPendingApplicationSurfaceStop(
                    sessionID: sessionID,
                    helperIdentity: identity
                )
                await stopHelperAfterLastDemand()
            }
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        applicationSurfaceSessionIDsByLease[lease.identifier, default: []]
            .insert(sessionID)
        applicationSurfaceInputConnections.register(
            connection,
            for: sessionID
        )
        return descriptor
    }

    func stopApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async {
        guard
            !sessionID.isEmpty,
            lease.service === self,
            applicationSurfaceLeaseIdentifiers.contains(lease.identifier)
        else {
            return
        }
        applicationSurfaceFailureEventRegistry.finish(sessionID: sessionID)
        guard let identity = try? validatedApplicationSurfaceIdentity(lease: lease) else {
            applicationSurfaceInputConnections.removeConnection(for: sessionID)
            applicationSurfaceSessionIDsByLease[lease.identifier]?.remove(sessionID)
            return
        }
        let connection = applicationSurfaceInputConnections.connection(
            for: sessionID
        )
        let response = await requestApplicationSurfaceStop(
            sessionID: sessionID,
            expectedPeerIdentity: identity,
            persistentConnection: connection
        )
        applicationSurfaceInputConnections.removeConnection(for: sessionID)
        if Self.applicationSurfaceStopWasAcknowledged(response) {
            applicationSurfacePendingStops.removeValue(forKey: sessionID)
            applicationSurfaceSessionIDsByLease[lease.identifier]?.remove(sessionID)
        } else {
            recordPendingApplicationSurfaceStop(
                sessionID: sessionID,
                helperIdentity: identity
            )
        }
    }

    func applicationSurfaceFailureEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) -> AsyncStream<ApplicationSurfaceRuntimeError> {
        guard
            !sessionID.isEmpty,
            lease.service === self,
            applicationSurfaceSessionIDsByLease[lease.identifier]?
                .contains(sessionID) == true
        else {
            return AsyncStream { continuation in
                continuation.yield(.helperUnavailable)
                continuation.finish()
            }
        }
        return applicationSurfaceFailureEventRegistry.events(for: sessionID)
    }

    func acknowledgeApplicationSurfaceAttachment(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async throws {
        let identity = try validatedApplicationSurfaceIdentity(lease: lease)
        guard
            !sessionID.isEmpty,
            applicationSurfaceSessionIDsByLease[lease.identifier]?
                .contains(sessionID) == true,
            let connection = applicationSurfaceInputConnections.connection(
                for: sessionID
            )
        else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        let response = await Self.sendDaemonRequest(
            [
                "method": "application_surface_attach",
                "args": ["session": sessionID],
            ],
            paths: paths,
            transport: transport,
            timeout: 3,
            expectedPeerIdentity: identity,
            socketURL: paths.daemonSocketURL,
            persistentConnection: connection
        )
        guard Self.applicationSurfaceAttachmentWasAcknowledged(response) else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
    }

    func sendApplicationSurfaceEvent(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) async throws {
        try await sendApplicationSurfaceEvents(
            lease: lease,
            sessionID: sessionID,
            events: [event]
        )
    }

    func sendApplicationSurfaceEvents(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        events: [ApplicationSurfaceInputEvent]
    ) async throws {
        let identity = try validatedApplicationSurfaceIdentity(lease: lease)
        guard
            !sessionID.isEmpty,
            !events.isEmpty,
            events.count <= 64,
            applicationSurfaceSessionIDsByLease[lease.identifier]?
                .contains(sessionID) == true,
            let connection = applicationSurfaceInputConnections.connection(
                for: sessionID
            )
        else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        let args: [String: Any] = [
            "events": events.map {
                Self.applicationSurfaceEventArguments(
                    sessionID: sessionID,
                    event: $0
                )
            },
        ]
        guard let response = await Self.sendDaemonRequest(
            [
                "method": "application_surface_events",
                "args": args,
            ],
            paths: paths,
            transport: transport,
            timeout: 3,
            expectedPeerIdentity: identity,
            socketURL: paths.daemonSocketURL,
            persistentConnection: connection
        ) else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        try Self.throwApplicationSurfaceResponseError(response)
    }

    nonisolated static func applicationSurfaceEventArguments(
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) -> [String: Any] {
        [
            "session": sessionID,
            "kind": event.kind.rawValue,
            "frame_sequence": Int64(clamping: event.frameSequence),
            "x": event.x,
            "y": event.y,
            "key_code": Int(event.keyCode),
            "key_down": event.keyDown,
            "modifiers": event.modifiers,
            "click_count": event.clickCount,
            "delta_x": event.deltaX,
            "delta_y": event.deltaY,
        ]
    }

    private func validatedApplicationSurfaceIdentity(
        lease: ApplicationSurfaceRuntimeLease
    ) throws -> AgentPIDProcessIdentity {
        guard
            lease.service === self,
            applicationSurfaceLeaseIdentifiers.contains(lease.identifier),
            desiredEnabled,
            acceptsNewLaunches,
            let identity = processIdentity(for: .native),
            AgentPIDProcessIdentity(pid: identity.pid) == identity
        else {
            throw ApplicationSurfaceRuntimeError.helperUnavailable
        }
        return identity
    }

    private func requestApplicationSurfaceStop(
        sessionID: String,
        expectedPeerIdentity: AgentPIDProcessIdentity,
        persistentConnection: PersistentSocketLineConnection? = nil
    ) async -> [String: Any]? {
        await Self.sendDaemonRequest(
            [
                "method": "application_surface_stop",
                "args": ["session": sessionID],
            ],
            paths: paths,
            transport: transport,
            timeout: 3,
            expectedPeerIdentity: expectedPeerIdentity,
            socketURL: paths.daemonSocketURL,
            persistentConnection: persistentConnection
        )
    }

    nonisolated static func applicationSurfaceStopWasAcknowledged(
        _ response: [String: Any]?
    ) -> Bool {
        guard
            response?["ok"] as? Bool == true,
            let result = response?["result"] as? [String: Any],
            result["stopped"] is Bool
        else {
            return false
        }
        return true
    }

    nonisolated static func applicationSurfaceAttachmentWasAcknowledged(
        _ response: [String: Any]?
    ) -> Bool {
        guard
            response?["ok"] as? Bool == true,
            let result = response?["result"] as? [String: Any]
        else {
            return false
        }
        return result["attached"] as? Bool == true
    }

    nonisolated static func applicationSurfaceStopFailureAction(
        failedAttemptCount: Int,
        helperRestartAttempted: Bool
    ) -> ApplicationSurfaceStopFailureAction {
        guard
            failedAttemptCount
                >= ApplicationSurfacePendingStop.maximumFailedAttemptCount
        else {
            return .retry
        }
        return helperRestartAttempted
            ? .retainUntilHelperExit
            : .restartHelper
    }

    nonisolated static func parseApplicationSurfaceStartResult(
        _ result: [String: Any]
    ) -> (
        sessionID: String?,
        descriptor: ApplicationSurfaceSessionDescriptor?
    ) {
        let sessionID = (result["sessionId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let sessionID,
            !sessionID.isEmpty,
            sessionID.count <= 128
        else {
            return (nil, nil)
        }
        guard
            let frame = result["frameTransport"] as? [String: Any],
            let sharedMemoryName = frame["sharedMemoryName"] as? String,
            !sharedMemoryName.isEmpty,
            let width = frame["width"] as? Int,
            width > 0,
            let height = frame["height"] as? Int,
            height > 0,
            let bytesPerRow = frame["bytesPerRow"] as? Int,
            bytesPerRow > 0,
            let slotCount = frame["slotCount"] as? Int,
            slotCount > 0,
            let sharedMemoryByteCount = frame["sharedMemoryByteCount"] as? Int,
            sharedMemoryByteCount > 0
        else {
            return (sessionID, nil)
        }
        return (
            sessionID,
            ApplicationSurfaceSessionDescriptor(
                sessionID: sessionID,
                frameTransport: SimulatorFrameTransportDescriptor(
                    sharedMemoryName: sharedMemoryName,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow,
                    slotCount: slotCount,
                    sharedMemoryByteCount: sharedMemoryByteCount
                )
            )
        )
    }

    private func recordPendingApplicationSurfaceStop(
        sessionID: String,
        helperIdentity: AgentPIDProcessIdentity
    ) {
        let failedAttemptCount: Int
        let helperRestartAttempted: Bool
        if let pending = applicationSurfacePendingStops[sessionID],
           pending.helperIdentity == helperIdentity {
            failedAttemptCount = min(
                pending.failedAttemptCount + 1,
                ApplicationSurfacePendingStop.maximumFailedAttemptCount
            )
            helperRestartAttempted = pending.helperRestartAttempted
        } else {
            failedAttemptCount = 1
            helperRestartAttempted = false
        }
        applicationSurfacePendingStops[sessionID] = ApplicationSurfacePendingStop(
            sessionID: sessionID,
            helperIdentity: helperIdentity,
            failedAttemptCount: failedAttemptCount,
            helperRestartAttempted: helperRestartAttempted
        )
    }

    private func retryPendingApplicationSurfaceStops(
        expectedPeerIdentity: AgentPIDProcessIdentity
    ) async {
        let pendingStops = Array(applicationSurfacePendingStops.values)
        guard !pendingStops.isEmpty else { return }
        for pending in pendingStops {
            guard !Task.isCancelled else { return }
            guard pending.helperIdentity == expectedPeerIdentity else {
                clearPendingApplicationSurfaceStops(
                    for: pending.helperIdentity
                )
                continue
            }
            switch Self.applicationSurfaceStopFailureAction(
                failedAttemptCount: pending.failedAttemptCount,
                helperRestartAttempted: pending.helperRestartAttempted
            ) {
            case .retry:
                break
            case .restartHelper:
                guard scheduleHelperRestartAfterApplicationSurfaceStopFailure(
                    expectedPeerIdentity: expectedPeerIdentity
                ) else {
                    continue
                }
                var retained = pending
                retained.helperRestartAttempted = true
                applicationSurfacePendingStops[pending.sessionID] = retained
                continue
            case .retainUntilHelperExit:
                continue
            }
            let response = await requestApplicationSurfaceStop(
                sessionID: pending.sessionID,
                expectedPeerIdentity: expectedPeerIdentity
            )
            if Self.applicationSurfaceStopWasAcknowledged(response) {
                applicationSurfacePendingStops.removeValue(
                    forKey: pending.sessionID
                )
                removeTrackedApplicationSurfaceSession(pending.sessionID)
            } else {
                recordPendingApplicationSurfaceStop(
                    sessionID: pending.sessionID,
                    helperIdentity: expectedPeerIdentity
                )
            }
        }
    }

    @discardableResult
    private func scheduleHelperRestartAfterApplicationSurfaceStopFailure(
        expectedPeerIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard
            recoveryTask == nil,
            desiredEnabled,
            acceptsNewLaunches,
            processIdentity(for: .native) == expectedPeerIdentity
        else {
            return false
        }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.serializeHelperLifecycle(cancelledResult: ()) {
                guard self.processIdentity(for: .native)
                    == expectedPeerIdentity
                else {
                    self.clearPendingApplicationSurfaceStops(
                        for: expectedPeerIdentity
                    )
                    return
                }
                guard
                    !Task.isCancelled,
                    self.acceptsNewLaunches
                else {
                    return
                }
                cmuxDebugLog(
                    "applicationSurface.stop.restartHelper"
                        + " pid=\(expectedPeerIdentity.pid)"
                )
                guard await self.stopDaemon() else { return }
                self.clearApplicationSurfaceSessionsAfterHelperExit()
                guard
                    !Task.isCancelled,
                    self.desiredEnabled,
                    self.acceptsNewLaunches
                else {
                    return
                }
                await self.startIfNeededWithinLifecycle()
            }
            self.recoveryTask = nil
        }
        return true
    }

    private func clearPendingApplicationSurfaceStops(
        for helperIdentity: AgentPIDProcessIdentity
    ) {
        let sessionIDs = applicationSurfacePendingStops.values.compactMap {
            $0.helperIdentity == helperIdentity ? $0.sessionID : nil
        }
        for sessionID in sessionIDs {
            applicationSurfacePendingStops.removeValue(forKey: sessionID)
            removeTrackedApplicationSurfaceSession(sessionID)
        }
    }

    private func clearApplicationSurfaceSessionsAfterHelperExit() {
        applicationSurfacePendingStops.removeAll()
        applicationSurfaceInputConnections.removeAllConnections()
        applicationSurfaceFailureEventRegistry.failAll(with: .helperUnavailable)
        for leaseIdentifier in Array(applicationSurfaceSessionIDsByLease.keys) {
            applicationSurfaceSessionIDsByLease[leaseIdentifier]?.removeAll()
        }
    }

    private func removeTrackedApplicationSurfaceSession(_ sessionID: String) {
        applicationSurfaceInputConnections.removeConnection(for: sessionID)
        applicationSurfaceFailureEventRegistry.finish(sessionID: sessionID)
        for leaseIdentifier in Array(applicationSurfaceSessionIDsByLease.keys) {
            applicationSurfaceSessionIDsByLease[leaseIdentifier]?.remove(sessionID)
        }
    }

    nonisolated static func applicationWindowDescriptor(
        _ value: [String: Any]
    ) -> ApplicationWindowDescriptor? {
        guard
            let rawWindowID = value["window_id"] as? NSNumber,
            let rawProcessID = value["process_id"] as? NSNumber,
            rawWindowID.uint64Value > 0,
            rawWindowID.uint64Value <= UInt32.max,
            rawProcessID.int64Value > 0,
            rawProcessID.int64Value <= Int32.max,
            let owner = value["owner"] as? String,
            let title = value["title"] as? String,
            let rawWidth = value["width"] as? NSNumber,
            let rawHeight = value["height"] as? NSNumber
        else {
            return nil
        }
        let width = rawWidth.doubleValue
        let height = rawHeight.doubleValue
        guard
            width.isFinite,
            height.isFinite,
            (1...maximumApplicationWindowDimension).contains(width),
            (1...maximumApplicationWindowDimension).contains(height)
        else {
            return nil
        }
        return ApplicationWindowDescriptor(
            windowID: rawWindowID.uint32Value,
            processID: rawProcessID.int32Value,
            owner: owner,
            title: title,
            width: width,
            height: height
        )
    }

    nonisolated static func throwApplicationSurfaceResponseError(
        _ response: [String: Any]
    ) throws {
        guard response["ok"] as? Bool == true else {
            switch response["error_code"] as? String {
            case "permission_required":
                throw ApplicationSurfaceRuntimeError.permissionRequired
            case "window_unavailable":
                throw ApplicationSurfaceRuntimeError.windowUnavailable
            case "point_outside_content":
                throw ApplicationSurfaceRuntimeError.pointOutsideContent
            case "capture_unavailable":
                throw ApplicationSurfaceRuntimeError.captureUnavailable
            case "resource_limit":
                throw ApplicationSurfaceRuntimeError.resourceLimit
            case "session_unavailable":
                throw ApplicationSurfaceRuntimeError.helperUnavailable
            default:
                throw ApplicationSurfaceRuntimeError.invalidResponse
            }
        }
    }

    /// Verifies the helper can perform direct ScreenCaptureKit capture now.
    ///
    /// On macOS 26 this is the prompt-capable check for the separate private
    /// window picker bypass consent. It is called only from the Screenshots
    /// onboarding step after the ordinary Screen Recording grant is present.
    func verifyDirectScreenCapture() async -> Bool {
        await verifyDirectScreenCaptureOutcome() == .ready
    }

    func verifyDirectScreenCaptureOutcome()
        async -> ComputerUseDirectScreenCaptureVerification
    {
        await serializeHelperLifecycle(cancelledResult: .unavailable) { [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                !Task.isCancelled
            else {
                return .unavailable
            }
            await self.startIfNeededWithinLifecycle()
            guard !Task.isCancelled else {
                return .unavailable
            }
            let expectedPeerIdentities = Dictionary(
                uniqueKeysWithValues: ComputerUseDaemonProfile.allCases
                    .compactMap { profile in
                        self.processIdentity(for: profile).map {
                            (profile, $0)
                        }
                    }
            )
            return await Self.verifyDirectScreenCaptureOutcomes(
                paths: self.paths,
                transport: self.transport,
                expectedPeerIdentities: expectedPeerIdentities
            )
        }
    }

    /// Verifies every helper profile that can perform a real capture. Tahoe's
    /// direct-capture consent can be process-generation scoped, so validating
    /// only the native daemon lets the Codex compatibility daemon prompt later
    /// during the first actual Computer Use call.
    nonisolated static func verifyDirectScreenCaptureOutcomes(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentities:
            [ComputerUseDaemonProfile: AgentPIDProcessIdentity]
    ) async -> ComputerUseDirectScreenCaptureVerification {
        for profile in ComputerUseDaemonProfile.allCases {
            guard
                let expectedPeerIdentity = expectedPeerIdentities[profile],
                AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                    == expectedPeerIdentity
            else {
                return .unavailable
            }
            let result = await verifyDirectScreenCaptureOutcome(
                paths: paths,
                transport: transport,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: Self.socketURL(for: profile, paths: paths)
            )
            guard result == .ready else { return result }
        }
        return .ready
    }

    /// Socket-level host request kept internal for peer/capability regression
    /// coverage. A normal bearer token cannot invoke this daemon method.
    nonisolated static func verifyDirectScreenCapture(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentity: AgentPIDProcessIdentity
    ) async -> Bool {
        await verifyDirectScreenCaptureOutcome(
            paths: paths,
            transport: transport,
            expectedPeerIdentity: expectedPeerIdentity
        ) == .ready
    }

    nonisolated static func verifyDirectScreenCaptureOutcome(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentity: AgentPIDProcessIdentity,
        socketURL: URL? = nil
    ) async -> ComputerUseDirectScreenCaptureVerification {
        guard
            let response = await sendDaemonRequest(
                ["method": "verify_screen_capture"],
                paths: paths,
                transport: transport,
                timeout: 60,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: socketURL ?? paths.daemonSocketURL
            )
        else {
            return .unavailable
        }
        guard
            response["ok"] as? Bool == true,
            let result = response["result"] as? [String: Any],
            let capturable = result["capturable"] as? Bool
        else {
            return .unavailable
        }
        return capturable ? .ready : .notCapturable
    }

    /// Ends one exact cmux-managed proxy generation through the authenticated
    /// helper that owns its lifecycle state.
    func endDriverSession(
        _ driverSessionID: String,
        proxySessionID: String
    ) async -> Bool {
        guard ComputerUseSessionScope.isManagedProxySessionID(
            proxySessionID,
            for: driverSessionID
        ) else { return false }
        return await serializeHelperLifecycle(cancelledResult: false) { [weak self] in
            guard let self, self.desiredEnabled, self.acceptsNewLaunches else {
                return false
            }
            var ended = false
            for profile in ComputerUseDaemonProfile.allCases {
                guard
                    let request = Self.endDriverSessionRequest(
                        driverSessionID: driverSessionID,
                        proxySessionID: proxySessionID,
                        profile: profile
                    ),
                    let expectedPeerIdentity = self.processIdentity(for: profile),
                    AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                        == expectedPeerIdentity
                else {
                    continue
                }
                let response = await Self.sendDaemonRequest(
                    request,
                    paths: self.paths,
                    transport: self.transport,
                    timeout: 3,
                    expectedPeerIdentity: expectedPeerIdentity,
                    socketURL: self.socketURL(for: profile)
                )
                ended =
                    response?["ok"] as? Bool == true
                        || ended
            }
            return ended
        }
    }

    nonisolated static func endDriverSessionRequest(
        driverSessionID: String,
        proxySessionID: String,
        profile: ComputerUseDaemonProfile
    ) -> [String: Any]? {
        guard ComputerUseSessionScope.isManagedProxySessionID(
            proxySessionID,
            for: driverSessionID
        ) else {
            return nil
        }
        switch profile {
        case .native:
            return [
                "method": "call",
                "name": "end_session",
                "args": ["session": proxySessionID],
            ]
        case .codexCompatibility:
            return [
                "method": "session_end",
                "session_id": proxySessionID,
            ]
        }
    }

    /// Shows or hides both the stable cursor owned by one cmux surface and the
    /// exact authenticated proxy generation that wrote the current state. The
    /// stable identity carries the choice into later calls; the exact identity
    /// owns the cursor feed that may already be visible.
    func setDriverCursorVisible(
        _ visible: Bool,
        driverSessionID: String,
        proxySessionID: String? = nil,
        while effectIsCurrent:
            @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> Bool {
        guard
            ComputerUseSessionScope.isManagedDriverSessionID(driverSessionID),
            (proxySessionID.map {
                ComputerUseSessionScope.isManagedProxySessionID(
                    $0,
                    for: driverSessionID
                )
            } ?? true),
            effectIsCurrent()
        else {
            return false
        }
        return await serializeHelperLifecycle(cancelledResult: false) { [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                effectIsCurrent()
            else {
                return false
            }
            var updated = false
            for profile in ComputerUseDaemonProfile.allCases {
                let cursorSessionIDs: [String]
                switch profile {
                case .native:
                    cursorSessionIDs = [driverSessionID]
                case .codexCompatibility:
                    if let proxySessionID,
                       proxySessionID != driverSessionID {
                        cursorSessionIDs = [
                            proxySessionID,
                            driverSessionID,
                        ]
                    } else {
                        cursorSessionIDs = [driverSessionID]
                    }
                }
                for cursorSessionID in cursorSessionIDs {
                    guard
                        effectIsCurrent(),
                        let request = Self.setDriverCursorVisibleRequest(
                            visible,
                            driverSessionID: cursorSessionID,
                            profile: profile
                        ),
                        let expectedPeerIdentity = self.processIdentity(for: profile),
                        AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                            == expectedPeerIdentity
                    else {
                        continue
                    }
                    let response = await Self.sendDaemonRequest(
                        request,
                        paths: self.paths,
                        transport: self.transport,
                        timeout: 3,
                        expectedPeerIdentity: expectedPeerIdentity,
                        socketURL: self.socketURL(for: profile)
                    )
                    guard effectIsCurrent() else { return false }
                    updated =
                        response?["ok"] as? Bool == true
                            || updated
                }
            }
            return updated
        }
    }

    nonisolated static func setDriverCursorVisibleRequest(
        _ visible: Bool,
        driverSessionID: String,
        profile: ComputerUseDaemonProfile
    ) -> [String: Any]? {
        switch profile {
        case .native:
            guard
                ComputerUseSessionScope.isManagedDriverSessionID(
                    driverSessionID
                )
            else {
                return nil
            }
            return [
                "method": "call",
                "name": "set_agent_cursor_enabled",
                "args": [
                    "cursor_id": driverSessionID,
                    "enabled": visible,
                ],
            ]
        case .codexCompatibility:
            guard
                ComputerUseSessionScope.driverSessionID(
                    containing: driverSessionID
                ) != nil
            else {
                return nil
            }
            return [
                "method": "set_cursor_enabled",
                "args": [
                    "session": driverSessionID,
                    "enabled": visible,
                ],
            ]
        }
    }

    private func startIfNeeded() async {
        await serializeHelperLifecycle(cancelledResult: ()) { [weak self] in
            guard let self else { return }
            await self.startIfNeededWithinLifecycle()
        }
    }

    private func stopHelperAfterLastDemand() async {
        guard !desiredEnabled else { return }
        helperHealthTask?.cancel()
        helperHealthTask = nil
        missedHelperHealthChecks = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        let helperStopped = await serializeHelperLifecycle(cancelledResult: false) { [weak self] in
            guard let self, !self.desiredEnabled else { return false }
            return await self.stopDaemon()
        }
        if helperStopped {
            clearApplicationSurfaceSessionsAfterHelperExit()
            cancelFinalHelperCleanup()
        } else if Self.shouldScheduleFinalHelperCleanup(
            desiredEnabled: desiredEnabled,
            helperStopped: helperStopped
        ) {
            scheduleFinalHelperCleanup()
        }
        guard !desiredEnabled else { return }
        try? FileManager.default.removeItem(at: paths.authenticationTokenFileURL)
        cachedStatus = .unknown
    }

    nonisolated static func shouldScheduleFinalHelperCleanup(
        desiredEnabled: Bool,
        helperStopped: Bool
    ) -> Bool {
        !desiredEnabled && !helperStopped
    }

    nonisolated static func finalHelperCleanupRetryDelay(
        afterFailedAttempt failedAttempt: Int
    ) -> Duration? {
        guard failedAttempt >= 0, failedAttempt < 4 else { return nil }
        return .seconds(1 << failedAttempt)
    }

    /// Performs four serialized, exponentially delayed cleanup attempts after
    /// the last pane closes. If the exact helper still has not exited, the
    /// termination observer retains passive ownership without recurring work.
    private func scheduleFinalHelperCleanup() {
        guard
            finalHelperCleanupTask == nil,
            finalHelperCleanupState == .idle
        else {
            return
        }
        let generation = UUID()
        finalHelperCleanupGeneration = generation
        finalHelperCleanupState = .retrying
        finalHelperCleanupTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var failedAttempt = 0
            while let delay = Self.finalHelperCleanupRetryDelay(
                afterFailedAttempt: failedAttempt
            ) {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard await self?.retryFinalHelperCleanupOnce() == true else {
                    break
                }
                failedAttempt += 1
            }
            guard
                let self,
                self.finalHelperCleanupGeneration == generation
            else {
                return
            }
            self.finalHelperCleanupTask = nil
            if
                !Task.isCancelled,
                !self.desiredEnabled,
                Self.finalHelperCleanupRetryDelay(
                    afterFailedAttempt: failedAttempt
                ) == nil
            {
                self.finalHelperCleanupState = .awaitingTermination
            } else {
                self.finalHelperCleanupState = .idle
            }
        }
    }

    private func retryFinalHelperCleanupOnce() async -> Bool {
        guard !desiredEnabled else { return false }
        let helperStopped = await serializeHelperLifecycle(
            cancelledResult: false
        ) { [weak self] in
            guard let self, !self.desiredEnabled else { return false }
            return await self.stopDaemon()
        }
        if helperStopped {
            clearApplicationSurfaceSessionsAfterHelperExit()
        }
        return Self.shouldScheduleFinalHelperCleanup(
            desiredEnabled: desiredEnabled,
            helperStopped: helperStopped
        )
    }

    private func cancelFinalHelperCleanup() {
        finalHelperCleanupGeneration = UUID()
        finalHelperCleanupTask?.cancel()
        finalHelperCleanupTask = nil
        finalHelperCleanupState = .idle
    }

    private func serializeHelperLifecycle<Result: Sendable>(
        cancelledResult: Result,
        _ operation: @escaping @MainActor @Sendable () async -> Result
    ) async -> Result {
        let predecessor = helperLifecycleTask
        helperLifecycleGeneration &+= 1
        let generation = helperLifecycleGeneration
        let operationTask = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return cancelledResult }
            return await operation()
        }
        helperLifecycleCancellationActions[generation] = {
            operationTask.cancel()
        }
        helperLifecycleTask = Task { @MainActor in
            _ = await operationTask.value
        }
        let result = await withTaskCancellationHandler {
            await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
        helperLifecycleCancellationActions.removeValue(forKey: generation)
        if generation == helperLifecycleGeneration {
            helperLifecycleTask = nil
        }
        return result
    }

    /// Invoked after an already-installed helper bundle is replaced by a
    /// different build. Tahoe's direct-capture consent follows the helper's
    /// code signature, so any cached "capture verified" state is stale the
    /// moment the installed build changes and must be re-verified through
    /// onboarding rather than surprising the user mid-session.
    var helperBuildReplacedHandler: (@MainActor () -> Void)?

    private func ensureStandaloneHelperInstalledWithinLifecycle() async -> URL? {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return nil }
        guard let bundledHelperAppURL else { return nil }
        let destination = paths.installedHelperAppURL
        let currentCheckTask = Task.detached(priority: .userInitiated) {
            Self.helperIsCurrent(nested: bundledHelperAppURL, destination: destination)
        }
        let isCurrent = await withTaskCancellationHandler {
            await currentCheckTask.value
        } onCancel: {
            currentCheckTask.cancel()
        }
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        if isCurrent {
            installedHelperURL = destination
            return destination
        }

        guard await stopDaemon(), acceptsNewLaunches, !Task.isCancelled else { return nil }
        let replacesExistingHelper = FileManager.default.fileExists(
            atPath: destination.path
        )
        let directory = paths.installedHelperDirectoryURL
        let installationTask = Task.detached(priority: .userInitiated) {
            Self.installHelper(
                nested: bundledHelperAppURL,
                destination: destination,
                directory: directory
            )
        }
        let result = await withTaskCancellationHandler {
            await installationTask.value
        } onCancel: {
            installationTask.cancel()
        }
        guard acceptsNewLaunches, !Task.isCancelled else { return nil }
        installedHelperURL = result
        if result != nil, replacesExistingHelper {
            permissionPhase = permissionPhase.applying(.helperReplaced)
            cancelReadinessPublication()
            helperBuildReplacedHandler?()
        }
        return result
    }

    private func startIfNeededWithinLifecycle() async {
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        guard let helperURL = await ensureStandaloneHelperInstalledWithinLifecycle() else { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        let nativeListening = await Self.isDaemonListening(
            paths: paths,
            transport: transport,
            socketURL: paths.daemonSocketURL
        )
        let nativeReady: Bool
        if nativeListening {
            nativeReady = await configureHostAuthority(for: .native)
        } else {
            nativeReady = false
        }
        let codexListening = await Self.isDaemonListening(
            paths: paths,
            transport: transport,
            socketURL: paths.codexDaemonSocketURL
        )
        let codexReady: Bool
        if codexListening {
            codexReady = await configureHostAuthority(
                for: .codexCompatibility
            )
        } else {
            codexReady = false
        }
        if nativeReady, codexReady { return }
        guard acceptsNewLaunches, !Task.isCancelled else { return }
        // A failed probe does not prove that an older helper exited. Stop and
        // verify the exact installed helper before launching a replacement, or a
        // wedged process can retain TCC privileges beside the new daemon.
        guard await stopDaemon(), acceptsNewLaunches, !Task.isCancelled else { return }
        for profile in ComputerUseDaemonProfile.allCases {
            guard await launchHelper(at: helperURL, profile: profile) else {
                _ = await stopDaemon()
                return
            }
            guard acceptsNewLaunches, !Task.isCancelled else {
                _ = await stopDaemon()
                return
            }
            let socketURL = socketURL(for: profile)
            let readiness = daemonReadiness(for: profile, timeout: .seconds(5))
            guard await readiness.waitUntilReady({
                await Self.isDaemonListening(
                    paths: self.paths,
                    transport: self.transport,
                    socketURL: socketURL
                )
            }) else {
                _ = await stopDaemon()
                return
            }
            guard await configureHostAuthority(for: profile) else {
                _ = await stopDaemon()
                return
            }
        }
    }

    private func stopDaemon() async -> Bool {
        let helperURL = installedHelperURL ?? paths.installedHelperAppURL
        var processIdentifiers = Set(
            runningHelperApplications(at: helperURL).keys
        )
        for identity in runningHelperProcesses.values where
            AgentPIDProcessIdentity(pid: identity.pid) == identity
        {
            processIdentifiers.insert(identity.pid)
        }

        var gracefulShutdownSucceeded = true
        let targets: [(URL, AgentPIDProcessIdentity?)] = [
            (paths.daemonSocketURL, processIdentity(for: .native)),
            (
                paths.codexDaemonSocketURL,
                processIdentity(for: .codexCompatibility)
            ),
        ]
        for (socketURL, expectedPeerIdentity) in targets {
            guard await Self.isDaemonListening(
                paths: paths,
                transport: transport,
                socketURL: socketURL
            ) else {
                continue
            }
            recordExpectedTerminationOfRunningHelper(at: helperURL)
            guard
                let expectedPeerIdentity,
                AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                    == expectedPeerIdentity
            else {
                gracefulShutdownSucceeded = false
                continue
            }
            _ = await Self.sendDaemonRequest(
                ["method": "shutdown"],
                paths: paths,
                transport: transport,
                timeout: 2,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: socketURL
            )
            let readiness = ComputerUseDaemonReadiness(
                pidFileURL: socketURL.deletingPathExtension()
                    .appendingPathExtension("pid"),
                timeout: .seconds(3)
            )
            if !(await readiness.waitUntilStopped({
                await Self.isDaemonListening(
                    paths: self.paths,
                    transport: self.transport,
                    socketURL: socketURL
                )
            })) {
                gracefulShutdownSucceeded = false
            }
        }
        if gracefulShutdownSucceeded {
            if processIdentifiers.isEmpty {
                clearTrackedHelperProcess()
                return true
            }
            if await waitForHelperProcessesToExit(
                processIdentifiers,
                helperURL: helperURL,
                attempts: 10
            ) {
                clearTrackedHelperProcess()
                return true
            }
        }

        // A failed probe is ambiguous: either helper may be gone, or it may be
        // wedged while retaining TCC privileges and the current bearer token.
        // Fail closed by SIGKILLing only processes whose bundle URL exactly
        // matches our independently installed helper, then revoke both sockets.
        let terminated = await terminateRunningHelperAndWait(at: helperURL)
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
        try? FileManager.default.removeItem(at: paths.codexDaemonSocketURL)
        if terminated {
            clearTrackedHelperProcess()
        }
        return terminated
    }

    private func launchHelper(
        at helperURL: URL,
        profile: ComputerUseDaemonProfile
    ) async -> Bool {
        guard acceptsNewLaunches, !Task.isCancelled, prepareRuntimeForLaunch() else { return false }
        guard daemonReadiness(for: profile, timeout: .seconds(5)).prepare()
        else {
            return false
        }
        guard let launch = ComputerUseHelperLaunchConfiguration(
            paths: paths,
            profile: profile
        ) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = launch.arguments
        configuration.environment = launch.environment
        let launchedProcessIdentifier: pid_t? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: helperURL,
                configuration: configuration,
                completionHandler: Self.makeHelperLaunchCompletion(
                    continuation: continuation
                )
            )
        }
        guard let launchedProcessIdentifier else { return false }
        guard let launchedProcessIdentity = AgentPIDProcessIdentity(
            pid: launchedProcessIdentifier
        ) else {
            if let application = NSRunningApplication(
                processIdentifier: launchedProcessIdentifier
            ) {
                _ = application.forceTerminate()
            }
            return false
        }
        runningHelperProcesses[profile] = launchedProcessIdentity
        guard acceptsNewLaunches, !Task.isCancelled else {
            terminateRunningHelper(at: helperURL)
            return false
        }
        return true
    }

    private func configureStateAuthentication(
        for profile: ComputerUseDaemonProfile
    ) async -> Bool {
        let runningIdentity = processIdentity(for: profile)
        guard
            stateAuthenticationKey.count == 32,
            let runningIdentity
        else {
            return false
        }
        guard let response = await Self.sendDaemonRequest(
            [
                "method": "configure_state_authentication",
                "args": [
                    "key_base64": stateAuthenticationKey.base64EncodedString(),
                ],
            ],
            paths: paths,
            transport: transport,
            timeout: 2,
            expectedPeerIdentity: runningIdentity,
            socketURL: socketURL(for: profile)
        ) else {
            return false
        }
        return
            response["ok"] as? Bool == true
                && (response["result"] as? [String: Any])?[
                    "state_authentication"
                ] as? Bool == true
    }

    private func configureHostAuthority(
        for profile: ComputerUseDaemonProfile
    ) async -> Bool {
        guard await configureStateAuthentication(for: profile) else {
            return false
        }
        return await publishExternalPermissionReadiness(for: profile)
    }

    private func publishExternalPermissionReadiness(
        for profile: ComputerUseDaemonProfile
    ) async -> Bool {
        guard
            let runningIdentity = processIdentity(for: profile),
            AgentPIDProcessIdentity(pid: runningIdentity.pid)
                == runningIdentity
        else {
            return false
        }
        let ready = desiredEnabled && permissionPhase.isReady
        guard let response = await Self.sendDaemonRequest(
            [
                "method": "set_external_permission_ready",
                "args": ["ready": ready],
            ],
            paths: paths,
            transport: transport,
            timeout: 2,
            expectedPeerIdentity: runningIdentity,
            socketURL: socketURL(for: profile)
        ) else {
            return false
        }
        return
            response["ok"] as? Bool == true
                && (response["result"] as? [String: Any])?[
                    "external_permission_ready"
                ] as? Bool == ready
    }

    private func transitionPermissionPhase(
        _ event: ComputerUseRuntimePermissionPhase.Event
    ) {
        let nextPhase = permissionPhase.applying(event)
        guard nextPhase != permissionPhase else { return }
        permissionPhase = nextPhase
        scheduleReadinessPublication()
    }

    private func scheduleReadinessPublication() {
        readinessPublicationGeneration &+= 1
        let generation = readinessPublicationGeneration
        readinessPublicationTask?.cancel()
        readinessPublicationTask = Task { @MainActor [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                !Task.isCancelled,
                generation == self.readinessPublicationGeneration
            else {
                return
            }
            await self.startIfNeeded()
            guard
                !Task.isCancelled,
                generation == self.readinessPublicationGeneration
            else {
                return
            }
            self.readinessPublicationTask = nil
        }
    }

    private func cancelReadinessPublication() {
        readinessPublicationGeneration &+= 1
        readinessPublicationTask?.cancel()
        readinessPublicationTask = nil
    }

    private func socketURL(for profile: ComputerUseDaemonProfile) -> URL {
        Self.socketURL(for: profile, paths: paths)
    }

    nonisolated private static func socketURL(
        for profile: ComputerUseDaemonProfile,
        paths: ComputerUseRuntimePaths
    ) -> URL {
        switch profile {
        case .native:
            paths.daemonSocketURL
        case .codexCompatibility:
            paths.codexDaemonSocketURL
        }
    }

    private func processIdentity(
        for profile: ComputerUseDaemonProfile
    ) -> AgentPIDProcessIdentity? {
        runningHelperProcesses[profile]
    }

    private func daemonReadiness(
        for profile: ComputerUseDaemonProfile,
        timeout: Duration
    ) -> ComputerUseDaemonReadiness {
        let socketURL = socketURL(for: profile)
        return ComputerUseDaemonReadiness(
            pidFileURL: socketURL.deletingPathExtension()
                .appendingPathExtension("pid"),
            timeout: timeout
        )
    }

    /// Creates and validates the private runtime before any helper launch.
    /// Existing symlinks, foreign ownership, or permission failures abort the
    /// launch instead of falling through to a predictable shared `/tmp` path.
    func prepareRuntimeForLaunch() -> Bool {
        guard acceptsNewLaunches else { return false }
        let fileManager = FileManager.default
        let computerUseParent = paths.computerUseDirectoryURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: computerUseParent, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let privateDirectories = [
            paths.runtimeDirectoryURL.deletingLastPathComponent(),
            paths.runtimeDirectoryURL,
            paths.computerUseDirectoryURL,
            paths.stateDirectoryURL.deletingLastPathComponent().deletingLastPathComponent(),
            paths.stateDirectoryURL.deletingLastPathComponent(),
            paths.stateDirectoryURL,
        ]
        guard privateDirectories.allSatisfy(Self.ensurePrivateDirectory) else { return false }
        return Self.writeAuthenticationToken(paths.authenticationToken, to: paths.authenticationTokenFileURL)
    }

    /// Synchronously prevents relaunch and stops the out-of-process helper.
    /// App termination cannot rely on an unstructured async task surviving exit.
    func stopForTermination() {
        computerUseEnabled = false
        applicationSurfaceLeaseIdentifiers.removeAll()
        applicationSurfaceSessionIDsByLease.removeAll()
        applicationSurfaceInputConnections.removeAllConnections()
        applicationSurfaceFailureEventRegistry.finishAll()
        applicationSurfacePendingStops.removeAll()
        acceptsNewLaunches = false
        permissionRefreshGeneration &+= 1
        for cancel in helperLifecycleCancellationActions.values {
            cancel()
        }
        helperLifecycleCancellationActions.removeAll()
        helperLifecycleTask?.cancel()
        helperLifecycleTask = nil
        helperLifecycleGeneration &+= 1
        helperTerminationObservationTask?.cancel()
        helperTerminationObservationTask = nil
        helperHealthTask?.cancel()
        helperHealthTask = nil
        missedHelperHealthChecks = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelFinalHelperCleanup()
        cancelReadinessPublication()
        terminateRunningHelper(at: installedHelperURL ?? paths.installedHelperAppURL)
        clearTrackedHelperProcess()
        try? FileManager.default.removeItem(at: paths.daemonSocketURL)
        try? FileManager.default.removeItem(at: paths.codexDaemonSocketURL)
        cachedStatus = .unknown
    }

    @discardableResult
    private func terminateRunningHelper(at helperURL: URL) -> Set<pid_t> {
        let applicationsByPID = runningHelperApplications(at: helperURL)
        var processIdentifiers = Set(applicationsByPID.keys)
        for identity in runningHelperProcesses.values where
            AgentPIDProcessIdentity(pid: identity.pid) == identity
        {
            processIdentifiers.insert(identity.pid)
            expectedTerminationProcessIdentifiers.insert(identity.pid)
            if applicationsByPID[identity.pid] == nil {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
        }
        for application in applicationsByPID.values {
            let pid = application.processIdentifier
            expectedTerminationProcessIdentifiers.insert(pid)
            guard !application.forceTerminate() else { continue }
            if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                continue
            }
        }
        return processIdentifiers
    }

    private func runningHelperApplications(
        at helperURL: URL
    ) -> [pid_t: NSRunningApplication] {
        let expectedURL = helperURL.standardizedFileURL
        var applicationsByPID: [pid_t: NSRunningApplication] = [:]
        for identity in runningHelperProcesses.values {
            let processIdentifier = identity.pid
            guard
                AgentPIDProcessIdentity(pid: processIdentifier) == identity,
                let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                ),
                application.bundleURL?.standardizedFileURL == expectedURL
            else {
                continue
            }
            applicationsByPID[processIdentifier] = application
        }
        if let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier {
            for application in NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ) where
                application.bundleURL?.standardizedFileURL == expectedURL
                    && !application.isTerminated
            {
                applicationsByPID[application.processIdentifier] = application
            }
        }
        return applicationsByPID
    }

    private func trackedHelperIdentity(
        for processIdentifier: pid_t
    ) -> AgentPIDProcessIdentity? {
        runningHelperProcesses.values.first {
            $0.pid == processIdentifier
                && AgentPIDProcessIdentity(pid: processIdentifier) == $0
        }
    }

    private func trackedHelperProfile(
        for processIdentifier: pid_t
    ) -> ComputerUseDaemonProfile? {
        runningHelperProcesses.first {
            $0.value.pid == processIdentifier
        }?.key
    }

    private func clearTrackedHelperProcess() {
        runningHelperProcesses.removeAll()
    }

    private func clearTrackedHelperProcess(
        for profile: ComputerUseDaemonProfile
    ) {
        runningHelperProcesses.removeValue(forKey: profile)
    }

    private func recordExpectedTerminationOfRunningHelper(at helperURL: URL) {
        expectedTerminationProcessIdentifiers.formUnion(
            runningHelperProcesses.values.map(\.pid)
        )
        let expectedURL = helperURL.standardizedFileURL
        guard let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier else { return }
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where application.bundleURL?.standardizedFileURL == expectedURL {
            expectedTerminationProcessIdentifiers.insert(application.processIdentifier)
        }
    }

    private func terminateRunningHelperAndWait(at helperURL: URL) async -> Bool {
        let processIdentifiers = terminateRunningHelper(at: helperURL)
        guard !processIdentifiers.isEmpty else { return true }
        if await waitForHelperProcessesToExit(
            processIdentifiers,
            helperURL: helperURL,
            attempts: 10
        ) {
            return true
        }

        // `forceTerminate()` reports whether AppKit accepted the request, not
        // whether the process actually exited. Revalidate each pid's exact
        // tracked generation or bundle URL before escalating so pid reuse
        // cannot kill an unrelated application.
        let expectedURL = helperURL.standardizedFileURL
        var signalSucceeded = true
        for pid in processIdentifiers {
            if trackedHelperIdentity(for: pid) != nil {
                if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                    signalSucceeded = false
                }
                continue
            }
            guard
                let application = NSRunningApplication(processIdentifier: pid),
                application.bundleURL?.standardizedFileURL == expectedURL
            else {
                continue
            }
            if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                signalSucceeded = false
            }
        }
        guard signalSucceeded else { return false }
        return await waitForHelperProcessesToExit(
            processIdentifiers,
            helperURL: helperURL,
            attempts: 20
        )
    }

    private func waitForHelperProcessesToExit(
        _ processIdentifiers: Set<pid_t>,
        helperURL: URL,
        attempts: Int
    ) async -> Bool {
        let expectedURL = helperURL.standardizedFileURL
        let clock = ContinuousClock()
        for attempt in 0 ... attempts {
            let stillRunning = processIdentifiers.contains { pid in
                if trackedHelperIdentity(for: pid) != nil {
                    return true
                }
                guard let application = NSRunningApplication(processIdentifier: pid) else {
                    return false
                }
                return application.bundleURL?.standardizedFileURL == expectedURL
                    && !application.isTerminated
            }
            if !stillRunning { return true }
            guard attempt < attempts, !Task.isCancelled else { return false }
            do {
                try await clock.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func startObservingHelperTermination() {
        helperTerminationObservationTask = Task { @MainActor [weak self] in
            for await notification in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didTerminateApplicationNotification
            ) {
                guard !Task.isCancelled else { return }
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                else {
                    continue
                }
                self?.helperDidTerminate(application)
            }
        }
    }

    private func helperDidTerminate(_ application: NSRunningApplication) {
        let helperURL = installedHelperURL ?? paths.installedHelperAppURL
        let trackedProfile = trackedHelperProfile(
            for: application.processIdentifier
        )
        let isTrackedHelperProcess = trackedProfile != nil
        let matchesInstalledHelper =
            application.bundleURL?.standardizedFileURL
                == helperURL.standardizedFileURL
        if let trackedProfile {
            clearTrackedHelperProcess(for: trackedProfile)
        }
        let wasExpected = expectedTerminationProcessIdentifiers.remove(
            application.processIdentifier
        ) != nil
        if
            finalHelperCleanupState != .idle,
            !desiredEnabled,
            isTrackedHelperProcess || matchesInstalledHelper,
            runningHelperApplications(at: helperURL).isEmpty
        {
            clearApplicationSurfaceSessionsAfterHelperExit()
            cancelFinalHelperCleanup()
        }
        guard Self.shouldRecoverAfterHelperTermination(
            desiredEnabled: desiredEnabled,
            acceptsNewLaunches: acceptsNewLaunches,
            wasExpected: wasExpected,
            isTrackedHelperProcess: isTrackedHelperProcess,
            terminatedBundleIdentifier: application.bundleIdentifier,
            terminatedBundleURL: application.bundleURL,
            helperBundleIdentifier: Bundle(url: helperURL)?.bundleIdentifier,
            helperBundleURL: helperURL
        ) else {
            return
        }
        clearApplicationSurfaceSessionsAfterHelperExit()
        scheduleHelperRecovery()
    }

    private func startMonitoringHelperHealth() {
        guard desiredEnabled, acceptsNewLaunches, helperHealthTask == nil else { return }
        helperHealthTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else { return }
                await self.checkHelperHealth()
            }
        }
    }

    private func checkHelperHealth() async {
        async let nativeListening = Self.isDaemonListening(
            paths: paths,
            transport: transport,
            socketURL: paths.daemonSocketURL
        )
        async let codexListening = Self.isDaemonListening(
            paths: paths,
            transport: transport,
            socketURL: paths.codexDaemonSocketURL
        )
        let listeningResults = await (nativeListening, codexListening)
        let daemonListening = listeningResults.0 && listeningResults.1
        guard !Task.isCancelled else { return }
        if daemonListening {
            missedHelperHealthChecks = 0
            if let identity = processIdentity(for: .native),
               AgentPIDProcessIdentity(pid: identity.pid) == identity {
                await retryPendingApplicationSurfaceStops(
                    expectedPeerIdentity: identity
                )
            }
            return
        }

        missedHelperHealthChecks += 1
        guard missedHelperHealthChecks >= 2 else { return }
        missedHelperHealthChecks = 0
        guard Self.shouldScheduleHelperRecovery(
            desiredEnabled: desiredEnabled,
            acceptsNewLaunches: acceptsNewLaunches,
            daemonListening: daemonListening,
            recoveryInFlight: recoveryTask != nil
        ) else {
            return
        }
        clearApplicationSurfaceSessionsAfterHelperExit()
        scheduleHelperRecovery()
    }

    @discardableResult
    private func scheduleHelperRecovery() -> Task<Void, Never>? {
        guard desiredEnabled, acceptsNewLaunches else { return nil }
        if let recoveryTask {
            return recoveryTask
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startIfNeeded()
            self.recoveryTask = nil
        }
        recoveryTask = task
        return task
    }

    nonisolated static func shouldRecoverAfterHelperTermination(
        desiredEnabled: Bool,
        acceptsNewLaunches: Bool,
        wasExpected: Bool,
        isTrackedHelperProcess: Bool = false,
        terminatedBundleIdentifier: String?,
        terminatedBundleURL: URL?,
        helperBundleIdentifier: String?,
        helperBundleURL: URL
    ) -> Bool {
        guard desiredEnabled, acceptsNewLaunches, !wasExpected else { return false }
        if isTrackedHelperProcess { return true }
        guard let terminatedBundleIdentifier, let helperBundleIdentifier,
              terminatedBundleIdentifier == helperBundleIdentifier
        else {
            return false
        }
        return terminatedBundleURL?.standardizedFileURL == helperBundleURL.standardizedFileURL
    }

    nonisolated static func shouldScheduleHelperRecovery(
        desiredEnabled: Bool,
        acceptsNewLaunches: Bool,
        daemonListening: Bool,
        recoveryInFlight: Bool
    ) -> Bool {
        desiredEnabled
            && acceptsNewLaunches
            && !daemonListening
            && !recoveryInFlight
    }

    nonisolated private static func ensurePrivateDirectory(_ directoryURL: URL) -> Bool {
        let path = directoryURL.path
        var metadata = stat()
        if Darwin.lstat(path, &metadata) != 0 {
            guard errno == ENOENT, Darwin.mkdir(path, mode_t(0o700)) == 0 else { return false }
        }

        guard Darwin.lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              Darwin.chmod(path, mode_t(0o700)) == 0,
              Darwin.lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == geteuid(),
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o700)
        else {
            return false
        }
        return true
    }

    nonisolated private static func writeAuthenticationToken(_ token: String, to fileURL: URL) -> Bool {
        let descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) == 0
        else {
            return false
        }

        let bytes = Array((token + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
        else {
            return false
        }
        return true
    }

    private func openSystemSettings(_ deepLink: String) async -> Bool {
        guard let url = URL(string: deepLink) else { return false }
        guard let systemSettingsURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.systemSettingsBundleIdentifier
        ) else {
            return NSWorkspace.shared.open(url)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: systemSettingsURL,
                configuration: configuration,
                completionHandler: Self.makeWorkspaceOpenCompletion(
                    continuation: continuation
                )
            )
        }
    }

    /// LaunchServices invokes this completion on a concurrent queue. Construct
    /// it outside `MainActor` so Swift 6 does not install an actor-isolation
    /// precondition before the continuation can be resumed.
    nonisolated private static func makeHelperLaunchCompletion(
        continuation: CheckedContinuation<pid_t?, Never>
    ) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { application, error in
            continuation.resume(
                returning: error == nil ? application?.processIdentifier : nil
            )
        }
    }

    /// LaunchServices invokes this completion on a concurrent queue.
    nonisolated private static func makeWorkspaceOpenCompletion(
        continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (NSRunningApplication?, Error?) -> Void {
        { application, error in
            continuation.resume(returning: application != nil && error == nil)
        }
    }

    nonisolated private static func helperIsCurrent(nested: URL, destination: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        let fileManager = FileManager.default
        let nestedBinary = nested
            .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        let destinationBinary = destination
            .appendingPathComponent("Contents/MacOS/\(helperExecutableName)")
        guard fileManager.isExecutableFile(atPath: destinationBinary.path) else { return false }
        guard
            let nestedFiles = helperBundleRelativeFilePaths(at: nested),
            let destinationFiles = helperBundleRelativeFilePaths(at: destination),
            nestedFiles == destinationFiles
        else {
            return false
        }
        for relativePath in nestedFiles {
            guard !Task.isCancelled else { return false }
            let nestedFile = nested.appendingPathComponent(relativePath, isDirectory: false)
            let destinationFile = destination.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.contentsEqual(
                atPath: nestedFile.path,
                andPath: destinationFile.path
            ) else {
                return false
            }
        }
        return fileManager.contentsEqual(
            atPath: nestedBinary.path,
            andPath: destinationBinary.path
        )
    }

    nonisolated private static func helperBundleRelativeFilePaths(
        at root: URL
    ) -> Set<String>? {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        var paths: Set<String> = []
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            paths.insert(relativePath)
        }
        return paths
    }

    nonisolated private static func installHelper(
        nested: URL,
        destination: URL,
        directory: URL
    ) -> URL? {
        let fileManager = FileManager.default
        do {
            guard !Task.isCancelled else { return nil }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(
                ".cmux Computer Use.\(UUID().uuidString).app",
                isDirectory: true
            )
            try? fileManager.removeItem(at: temporary)
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: nested, to: temporary)
            guard !Task.isCancelled else { return nil }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    nonisolated private static func makeStateAuthenticationKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            == errSecSuccess
        {
            return Data(bytes)
        }
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    nonisolated private static func isDaemonListening(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        socketURL: URL
    ) async -> Bool {
        await sendDaemonRequest(
            ["method": "list"],
            paths: paths,
            transport: transport,
            timeout: 1,
            socketURL: socketURL
        )?["ok"] as? Bool == true
    }

    nonisolated private static func queryPermissionStatus(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> ComputerUsePermissionStatus? {
        guard
            let response = await sendDaemonRequest(
                [
                    "method": "call",
                    "name": "check_permissions",
                    "args": ["prompt": false],
                ],
                paths: paths,
                transport: transport,
                timeout: 2,
                socketURL: paths.daemonSocketURL
            ),
            response["ok"] as? Bool == true,
            let result = response["result"] as? [String: Any],
            let structured = result["structuredContent"] as? [String: Any]
        else {
            return nil
        }
        return ComputerUsePermissionStatus(structuredContent: structured)
    }

    nonisolated private static func sendDaemonRequest(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval,
        expectedPeerIdentity: AgentPIDProcessIdentity? = nil,
        socketURL: URL,
        persistentConnection: PersistentSocketLineConnection? = nil
    ) async -> [String: Any]? {
        let requestTask = Task.detached(priority: .userInitiated) {
            await performDaemonRequest(
                request,
                paths: paths,
                transport: transport,
                timeout: timeout,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: socketURL,
                persistentConnection: persistentConnection
            )
        }
        return await withTaskCancellationHandler {
            await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
    }

    #if DEBUG
    nonisolated static func sendDaemonRequestForTesting(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval,
        socketURL: URL,
        persistentConnection: PersistentSocketLineConnection
    ) async -> [String: Any]? {
        await sendDaemonRequest(
            request,
            paths: paths,
            transport: transport,
            timeout: timeout,
            socketURL: socketURL,
            persistentConnection: persistentConnection
        )
    }
    #endif

    nonisolated private static func performDaemonRequest(
        _ request: [String: Any],
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport,
        timeout: TimeInterval,
        expectedPeerIdentity: AgentPIDProcessIdentity? = nil,
        socketURL: URL,
        persistentConnection: PersistentSocketLineConnection? = nil
    ) async -> [String: Any]? {
        var authenticatedRequest: [String: Any] = [
            "auth_token": paths.authenticationToken,
            "request": request,
        ]
        if expectedPeerIdentity != nil {
            authenticatedRequest["host_auth_token"] =
                paths.hostAuthenticationToken
        }
        guard JSONSerialization.isValidJSONObject(authenticatedRequest),
              let data = try? JSONSerialization.data(
                  withJSONObject: authenticatedRequest
              ),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        let socketPath = socketURL.path
        let validatePeer: @Sendable (pid_t?) -> Bool = { peerProcessID in
            expectedPeerIdentity.map { expected in
                guard
                    peerProcessID == expected.pid,
                    let current = AgentPIDProcessIdentity(
                        pid: expected.pid
                    )
                else {
                    return false
                }
                return current == expected
            } ?? true
        }
        let probe: (response: String, peerProcessID: pid_t?)?
        if let persistentConnection {
            probe = await persistentConnection.command(
                line,
                at: socketPath,
                timeout: timeout,
                validatingPeer: validatePeer
            )
        } else {
            probe = transport.probeCommandWithPeerProcessID(
                line,
                at: socketPath,
                timeout: timeout,
                validatingPeer: validatePeer
            )
        }
        guard
            let probe,
            let data = probe.response.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    nonisolated private static func waitForPermissionStatus(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport
    ) async -> ComputerUsePermissionStatus? {
        if let status = await queryPermissionStatus(paths: paths, transport: transport) {
            return status
        }
        let events = directoryEvents(at: paths.runtimeDirectoryURL)
        if let status = await queryPermissionStatus(paths: paths, transport: transport) {
            return status
        }
        return await withTaskGroup(of: ComputerUsePermissionStatus?.self) { group in
            group.addTask {
                for await _ in events {
                    guard !Task.isCancelled else { return nil }
                    if let status = await queryPermissionStatus(paths: paths, transport: transport) {
                        return status
                    }
                }
                return nil
            }
            group.addTask {
                // Genuine upper deadline; readiness itself is driven by directory events.
                try? await ContinuousClock().sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func directoryEvents(at directoryURL: URL) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            // DispatchSource is the system's only event-driven directory watcher.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .delete, .rename],
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }

    nonisolated private static func mergedFileSystemEvents(
        at urls: [URL],
        fallbackInterval: Duration
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observationTask = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls {
                        group.addTask {
                            for await _ in directoryEvents(at: url) {
                                guard !Task.isCancelled else { return }
                                continuation.yield()
                            }
                        }
                    }
                    group.addTask {
                        let clock = ContinuousClock()
                        while !Task.isCancelled {
                            do {
                                try await clock.sleep(for: fallbackInterval)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled else { return }
                            // Some macOS releases deny or coalesce filesystem
                            // observation of the user's TCC database. Keep one
                            // bounded passive status probe as a fallback so a
                            // real toggle is still observed promptly.
                            continuation.yield()
                        }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                observationTask.cancel()
            }
        }
    }
}
