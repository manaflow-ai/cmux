import AppKit
import CmuxSimulator
import CmuxSimulatorUI
import Foundation
import Observation

/// App-level panel shim for one isolated native Simulator session.
///
/// Mutable Simulator state lives in the Observation-based package coordinator.
/// This class conforms to the legacy `Panel`/`ObservableObject` boundary only
/// so the existing workspace registry can own it.
@MainActor
@Observable
final class SimulatorPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .simulator
    private(set) var coordinator: SimulatorPaneCoordinator

    private let clientFactory: @MainActor () -> any SimulatorPaneClient
    private var preferredDeviceID: String?
    private var preferredRuntimeIdentifier: String?
    private var preferredDeviceTypeIdentifier: String?
    @ObservationIgnored private var featureFlagsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private weak var focusOwnershipView: NSView?
    @ObservationIgnored private var featureTransitionGeneration = 0
    private var isFeatureDisabled = false
    private var isClosed = false
    private var isVisibleInUI = false
    private var canvasRendering: Bool?

    var displayTitle: String {
        String(localized: "simulator.pane.title", defaultValue: "Simulator")
    }

    var displayIcon: String? { "iphone" }

    var selectedDeviceID: String? { coordinator.selectedDevice?.id ?? preferredDeviceID }
    var selectedRuntimeIdentifier: String? {
        coordinator.selectedDevice?.runtimeIdentifier ?? preferredRuntimeIdentifier
    }
    var selectedDeviceTypeIdentifier: String? {
        coordinator.selectedDevice?.deviceTypeIdentifier ?? preferredDeviceTypeIdentifier
    }
    var selectedDeviceName: String? { coordinator.selectedDevice?.name }
    var selectedDeviceState: String? {
        if coordinator.status == .streaming { return SimulatorDeviceState.booted.rawValue }
        return coordinator.selectedDevice?.state.rawValue
    }

    init(
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        clientFactory: @escaping @MainActor () -> any SimulatorPaneClient = {
            SimulatorWorkerClientFactory().makeClient()
        }
    ) {
        self.clientFactory = clientFactory
        self.preferredDeviceID = preferredDeviceID
        self.preferredRuntimeIdentifier = preferredRuntimeIdentifier
        self.preferredDeviceTypeIdentifier = preferredDeviceTypeIdentifier
        coordinator = SimulatorPaneCoordinator(
            client: clientFactory(),
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier
        )
        featureFlagsObserver = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: CmuxFeatureFlags.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileRemoteFeatureFlag()
            }
        }
        reconcileRemoteFeatureFlag()
    }

    convenience init(
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        client: any SimulatorPaneClient
    ) {
        self.init(
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier,
            clientFactory: { client }
        )
    }

    func suspendForRemoteDisable() {
        guard !isClosed, !isFeatureDisabled else { return }
        isFeatureDisabled = true
        featureTransitionGeneration += 1
        rememberSelection()
        let coordinator = self.coordinator
        let startupTask = self.startupTask
        self.startupTask = nil
        startupTask?.cancel()
        let previousShutdown = shutdownTask
        shutdownTask = Task {
            await previousShutdown?.value
            _ = await startupTask?.value
            await coordinator.close()
        }
    }

    func resumeAfterRemoteEnable() {
        guard !isClosed, isFeatureDisabled else { return }
        isFeatureDisabled = false
        featureTransitionGeneration += 1
        let generation = featureTransitionGeneration
        let shutdownTask = self.shutdownTask
        Task { @MainActor [weak self] in
            await shutdownTask?.value
            guard let self,
                  !self.isClosed,
                  !self.isFeatureDisabled,
                  self.featureTransitionGeneration == generation else { return }
            self.shutdownTask = nil
            self.coordinator = SimulatorPaneCoordinator(
                client: self.clientFactory(),
                preferredDeviceID: self.preferredDeviceID,
                preferredRuntimeIdentifier: self.preferredRuntimeIdentifier,
                preferredDeviceTypeIdentifier: self.preferredDeviceTypeIdentifier
            )
            self.applyEffectiveVisibility()
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        guard !isClosed else { return }
        isVisibleInUI = visible
        applyEffectiveVisibility()
    }

    func setCanvasRendering(_ rendering: Bool?) {
        guard !isClosed else { return }
        canvasRendering = rendering
        applyEffectiveVisibility()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        featureTransitionGeneration += 1
        if let featureFlagsObserver {
            NotificationCenter.default.removeObserver(featureFlagsObserver)
            self.featureFlagsObserver = nil
        }
        let coordinator = self.coordinator
        let startupTask = self.startupTask
        self.startupTask = nil
        startupTask?.cancel()
        let pendingShutdown = shutdownTask
        Task {
            await pendingShutdown?.value
            _ = await startupTask?.value
            await coordinator.close()
        }
    }

    func focus() {
        coordinator.setActive(true)
    }

    func unfocus() {
        coordinator.setActive(false)
    }

    func setFocusOwnershipView(_ view: NSView) {
        focusOwnershipView = view
    }

    func clearFocusOwnershipView(_ view: NSView) {
        guard focusOwnershipView === view else { return }
        focusOwnershipView = nil
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        if let simulatorResponder = responder as? any SimulatorInputResponder,
           simulatorResponder.simulatorOwnerID == ObjectIdentifier(coordinator),
           (responder as? NSView)?.window === window {
            return .panel
        }

        guard let ownershipView = focusOwnershipView,
              ownershipView.window === window,
              let responderView = Self.focusView(for: responder),
              responderView.window === window else { return nil }
        let ownershipFrame = ownershipView.convert(ownershipView.bounds, to: nil)
        let responderFrame = responderView.convert(responderView.bounds, to: nil)
        guard ownershipFrame.contains(
            NSPoint(x: responderFrame.midX, y: responderFrame.midY)
        ) else { return nil }
        return .panel
    }

    private static func focusView(for responder: NSResponder) -> NSView? {
        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor,
           let control = fieldEditor.delegate as? NSView {
            return control
        }
        return responder as? NSView
    }

    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent == .panel,
              let responder = window.firstResponder,
              ownedFocusIntent(for: responder, in: window) == intent else {
            return false
        }
        coordinator.releaseInputs()
        return window.makeFirstResponder(nil)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func rememberSelection() {
        preferredDeviceID = selectedDeviceID
        preferredRuntimeIdentifier = selectedRuntimeIdentifier
        preferredDeviceTypeIdentifier = selectedDeviceTypeIdentifier
    }

    private func startCoordinator() {
        guard !isClosed, !isFeatureDisabled, isEffectivelyVisible, startupTask == nil else { return }
        let coordinator = self.coordinator
        startupTask = Task { await coordinator.start() }
    }

    private var isEffectivelyVisible: Bool {
        isVisibleInUI && (canvasRendering ?? true)
    }

    private func applyEffectiveVisibility() {
        let visible = isEffectivelyVisible
        coordinator.setPaneVisibility(visible)
        if visible { startCoordinator() }
    }

    private func reconcileRemoteFeatureFlag() {
        if CmuxFeatureFlags.shared.isSimulatorEnabled {
            resumeAfterRemoteEnable()
        } else {
            suspendForRemoteDisable()
        }
    }
}
