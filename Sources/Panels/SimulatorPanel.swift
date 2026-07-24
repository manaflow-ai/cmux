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
    private var requiresExplicitDeviceSelection: Bool
    @ObservationIgnored private var featureFlagsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var featureEnableTask: Task<Void, Never>?
    @ObservationIgnored private weak var focusOwnershipView: NSView?
    @ObservationIgnored private var directVisibleInUI = false
    @ObservationIgnored private var visibleUIHostIDs: Set<UUID> = []
    @ObservationIgnored private var featureTransitionGeneration = 0
    private var isFeatureDisabled = false
    private var isClosed = false
    private var isVisibleInUI = false
    private var canvasRendering: Bool?

    var isFeatureReady: Bool { !isFeatureDisabled && !isClosed }

    var displayTitle: String {
        String(localized: "simulator.pane.title", defaultValue: "Simulator")
    }

    var displayIcon: String? { "iphone" }

    var selectedDeviceID: String? {
        guard !coordinator.requiresExplicitDeviceSelection else { return nil }
        return coordinator.selectedDevice?.id ?? preferredDeviceID
    }
    var selectedRuntimeIdentifier: String? {
        guard !coordinator.requiresExplicitDeviceSelection else { return nil }
        return coordinator.selectedDevice?.runtimeIdentifier ?? preferredRuntimeIdentifier
    }
    var selectedDeviceTypeIdentifier: String? {
        guard !coordinator.requiresExplicitDeviceSelection else { return nil }
        return coordinator.selectedDevice?.deviceTypeIdentifier ?? preferredDeviceTypeIdentifier
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
        requiresExplicitDeviceSelection: Bool = false,
        clientFactory: @escaping @MainActor () -> any SimulatorPaneClient = {
            SimulatorWorkerClientFactory(
                locationOwnershipScope: TerminalController.shared.simulatorLocationOwnershipScope,
                cameraCleanupOwnershipScope:
                    TerminalController.shared.simulatorCameraCleanupOwnershipScope
            ).makeClient()
        }
    ) {
        self.clientFactory = clientFactory
        self.preferredDeviceID = preferredDeviceID
        self.preferredRuntimeIdentifier = preferredRuntimeIdentifier
        self.preferredDeviceTypeIdentifier = preferredDeviceTypeIdentifier
        self.requiresExplicitDeviceSelection = requiresExplicitDeviceSelection
        coordinator = SimulatorPaneCoordinator(
            client: clientFactory(),
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier,
            requiresExplicitDeviceSelection: requiresExplicitDeviceSelection
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
        requiresExplicitDeviceSelection: Bool = false,
        client: any SimulatorPaneClient
    ) {
        self.init(
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier,
            requiresExplicitDeviceSelection: requiresExplicitDeviceSelection,
            clientFactory: { client }
        )
    }

    func suspendForRemoteDisable() {
        guard !isClosed else { return }
        featureTransitionGeneration += 1
        featureEnableTask?.cancel()
        featureEnableTask = nil
        guard !isFeatureDisabled else { return }
        isFeatureDisabled = true
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
        guard !isClosed, isFeatureDisabled, featureEnableTask == nil else { return }
        featureTransitionGeneration += 1
        let generation = featureTransitionGeneration
        let shutdownTask = self.shutdownTask
        featureEnableTask = Task { @MainActor [weak self] in
            await shutdownTask?.value
            guard let self,
                  !self.isClosed,
                  self.isFeatureDisabled,
                  CmuxFeatureFlags.shared.isSimulatorEnabled,
                  self.featureTransitionGeneration == generation else { return }
            self.featureEnableTask = nil
            self.shutdownTask = nil
            self.coordinator = SimulatorPaneCoordinator(
                client: self.clientFactory(),
                preferredDeviceID: self.preferredDeviceID,
                preferredRuntimeIdentifier: self.preferredRuntimeIdentifier,
                preferredDeviceTypeIdentifier: self.preferredDeviceTypeIdentifier,
                requiresExplicitDeviceSelection: self.requiresExplicitDeviceSelection
            )
            self.isFeatureDisabled = false
            self.applyEffectiveVisibility()
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        guard !isClosed else { return }
        directVisibleInUI = visible
        applyRegisteredVisibility()
    }

    func setVisibleInUI(_ visible: Bool, hostID: UUID) {
        guard !isClosed else { return }
        if visible {
            visibleUIHostIDs.insert(hostID)
        } else {
            visibleUIHostIDs.remove(hostID)
        }
        applyRegisteredVisibility()
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
        featureEnableTask?.cancel()
        featureEnableTask = nil
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
        if coordinator.requiresExplicitDeviceSelection {
            preferredDeviceID = nil
            preferredRuntimeIdentifier = nil
            preferredDeviceTypeIdentifier = nil
            requiresExplicitDeviceSelection = true
            return
        }
        guard let selectedDevice = coordinator.selectedDevice else { return }
        preferredDeviceID = selectedDevice.id
        preferredRuntimeIdentifier = selectedDevice.runtimeIdentifier
        preferredDeviceTypeIdentifier = selectedDevice.deviceTypeIdentifier
        requiresExplicitDeviceSelection = false
    }

    private func startCoordinator() {
        guard !isClosed, !isFeatureDisabled, isEffectivelyVisible, startupTask == nil else { return }
        let coordinator = self.coordinator
        startupTask = Task { await coordinator.start() }
    }

    private var isEffectivelyVisible: Bool {
        isVisibleInUI && (canvasRendering ?? true)
    }

    private func applyRegisteredVisibility() {
        isVisibleInUI = directVisibleInUI || !visibleUIHostIDs.isEmpty
        applyEffectiveVisibility()
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
