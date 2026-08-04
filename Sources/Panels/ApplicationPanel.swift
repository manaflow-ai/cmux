import AppKit
import Darwin
import Foundation
import Observation

/// A cmux pane that selects, captures, and controls one native application window.
@MainActor
@Observable
final class ApplicationPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .application
    private(set) var workspaceId: UUID
    let targetFrameRate: Int
    let runtime: any ApplicationSurfaceRuntime
    @ObservationIgnored
    let pickerModel = ApplicationSurfacePickerModel()

    private(set) var windowID: CGWindowID?
    private(set) var processID: pid_t?
    private(set) var captureState: ApplicationCaptureState = .suspended
    private(set) var captureGeneration = UUID()

    private var targetTitle: String?
    private var captureRuntimeFailureDetail: String?
    @ObservationIgnored
    private var hostedView: ApplicationCaptureView?
    @ObservationIgnored
    private var activeCaptureToken: UUID?
    @ObservationIgnored
    private var pendingFocus = false
    @ObservationIgnored
    private var captureVisibleInUI = false
    @ObservationIgnored
    private var activeCaptureMountID: UUID?
    @ObservationIgnored
    private var canvasRendering: Bool?
    @ObservationIgnored
    private var runtimeLease: ApplicationSurfaceRuntimeLease?
    @ObservationIgnored
    private var pickerTask: Task<Void, Never>?
    @ObservationIgnored
    private var pickerRequestID = UUID()
    @ObservationIgnored
    private var isClosed = false
    @ObservationIgnored
    private var displayTitleDidChange: ((String) -> Void)?
    @ObservationIgnored
    private var hostFocusRequestHandler: (() -> Void)?
    @ObservationIgnored
    private let searchIndexPurge: @MainActor (UUID) -> Void

    var captureTarget: ApplicationCaptureTarget? {
        guard let windowID, let processID else { return nil }
        return ApplicationCaptureTarget(windowID: windowID, processID: processID)
    }

    var displayTitle: String {
        targetTitle
            ?? String(localized: "panel.application.defaultTitle", defaultValue: "Application")
    }

    var selectedWindowTitle: String {
        targetTitle ?? displayTitle
    }

    var displayIcon: String? { "macwindow" }
    var isCaptureViewInWindow: Bool { hostedView?.window != nil }
    var captureStateDescription: String {
        guard captureTarget != nil else {
            switch pickerModel.phase {
            case .idle, .ready:
                return "selecting"
            case .loading:
                return "loading_windows"
            case .permissionRequired:
                return "permission_required"
            case .helperUnavailable:
                return "helper_unavailable"
            case .failed:
                return "failed"
            }
        }
        switch captureState {
        case .starting: return "starting"
        case .streaming: return "streaming"
        case .suspended: return "suspended"
        case .permissionRequired: return "permission_required"
        case .windowUnavailable: return "window_unavailable"
        case .failed: return "failed"
        }
    }
    var captureFailureCode: String? {
        if case .failed = pickerModel.phase {
            return "window_list_failed"
        }
        return captureState == .failed ? "capture_failed" : nil
    }
    var captureFailureDetail: String? {
        if case .failed(let detail) = pickerModel.phase {
            return detail
        }
        return captureRuntimeFailureDetail
    }

    init?(
        id: UUID = UUID(),
        workspaceId: UUID,
        windowID: CGWindowID? = nil,
        processID: pid_t? = nil,
        title: String? = nil,
        targetFrameRate: Int,
        runtime: any ApplicationSurfaceRuntime,
        runtimeLease: ApplicationSurfaceRuntimeLease? = nil,
        searchIndexPurge: (@MainActor (UUID) -> Void)? = nil
    ) {
        guard (1...120).contains(targetFrameRate) else { return nil }
        guard (windowID == nil) == (processID == nil) else { return nil }
        if let windowID, let processID {
            guard
                windowID > 0,
                processID > 0,
                processID != getpid()
            else {
                return nil
            }
        }

        self.id = id
        self.workspaceId = workspaceId
        self.windowID = windowID
        self.processID = processID
        targetTitle = title
        self.targetFrameRate = min(max(targetFrameRate, 1), 120)
        self.runtime = runtime
        self.runtimeLease = runtimeLease
        self.searchIndexPurge = searchIndexPurge ?? { panelID in
            GlobalSearchCoordinator.shared.purgePanel(id: panelID)
        }
    }

    func beginWindowSelectionIfNeeded() {
        guard captureTarget == nil, pickerModel.phase == .idle else { return }
        refreshAvailableWindows()
    }

    func refreshAvailableWindows() {
        guard !isClosed, captureTarget == nil else { return }
        pickerTask?.cancel()
        let requestID = UUID()
        pickerRequestID = requestID
        pickerModel.phase = .loading
        pickerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pickerRequestID == requestID {
                    self.pickerTask = nil
                }
            }
            guard let lease = await self.applicationSurfaceLease() else {
                guard self.pickerRequestID == requestID, !Task.isCancelled else {
                    return
                }
                self.pickerModel.phase = .helperUnavailable
                return
            }
            do {
                let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
                let windows = try await self.runtime
                    .listApplicationWindows(lease: lease)
                    .filter { window in
                        window.processID != currentProcessID
                            && NSRunningApplication(
                                processIdentifier: pid_t(window.processID)
                            )?.activationPolicy == .regular
                    }
                guard
                    self.pickerRequestID == requestID,
                    !Task.isCancelled,
                    self.captureTarget == nil
                else {
                    return
                }
                self.pickerModel.replaceWindows(windows)
                self.pickerModel.phase = .ready
            } catch is CancellationError {
                return
            } catch ApplicationSurfaceRuntimeError.permissionRequired {
                guard self.pickerRequestID == requestID, !Task.isCancelled else {
                    return
                }
                self.pickerModel.phase = .permissionRequired
            } catch {
                guard self.pickerRequestID == requestID, !Task.isCancelled else {
                    return
                }
#if DEBUG
                cmuxDebugLog(
                    "applicationSurface.windows.failed"
                        + " error=\(error.localizedDescription)"
                )
#endif
                self.pickerModel.phase = .failed(String(
                    localized: "applicationSurface.picker.failed",
                    defaultValue: "Application windows could not be loaded."
                ))
            }
        }
    }

    func selectWindow(_ window: ApplicationWindowDescriptor) {
        guard
            !isClosed,
            window.windowID > 0,
            window.processID > 0,
            pid_t(window.processID) != getpid()
        else {
            return
        }
        pickerTask?.cancel()
        pickerTask = nil
        pickerRequestID = UUID()
        stopHostedCapture()
        windowID = CGWindowID(window.windowID)
        processID = pid_t(window.processID)
        targetTitle = window.title
        displayTitleDidChange?(displayTitle)
        pickerModel.selectedWindowID = window.windowID
        setCaptureState(.suspended)
        captureGeneration = UUID()
    }

    func chooseAnotherWindow() {
        guard !isClosed else { return }
        stopHostedCapture()
        windowID = nil
        processID = nil
        targetTitle = nil
        displayTitleDidChange?(displayTitle)
        setCaptureState(.suspended)
        captureGeneration = UUID()
        pickerModel.query = ""
        pickerModel.phase = .idle
        beginWindowSelectionIfNeeded()
    }

    func retryWindowLoadingAfterPermissions() {
        guard captureTarget == nil else {
            retryCaptureAfterPermissions()
            return
        }
        pickerModel.phase = .idle
        beginWindowSelectionIfNeeded()
    }

    func beginCaptureSession() -> UUID {
        stopHostedCapture()
        captureVisibleInUI = false
        activeCaptureMountID = nil
        canvasRendering = true
        let token = UUID()
        activeCaptureToken = token
        return token
    }

    func captureView(
        windowID: CGWindowID,
        processID: pid_t
    ) -> ApplicationCaptureView {
        if let hostedView {
            return hostedView
        }
        let captureToken = beginCaptureSession()
        let view = ApplicationCaptureView(
            windowID: windowID,
            processID: processID,
            targetFrameRate: targetFrameRate,
            runtime: runtime,
            leaseProvider: { [weak self] in
                await self?.applicationSurfaceLease()
            },
            onStateChanged: { [weak self] state, failureDetail in
                self?.updateCaptureState(
                    state,
                    failureDetail: failureDetail,
                    token: captureToken
                )
            },
            onMovedToWindow: { [weak self] view in
                self?.captureViewDidMoveToWindow(view, token: captureToken)
            },
            onPointerDown: { [weak self] in
                self?.hostFocusRequestHandler?()
            },
            onRepresentableDismantled: { [weak self] view, mountID in
                self?.endCaptureViewMount(mountID, view: view)
            }
        )
        attach(view, token: captureToken)
        return view
    }

    func setDisplayTitleChangeHandler(_ handler: ((String) -> Void)?) {
        displayTitleDidChange = handler
    }

    func setHostFocusRequestHandler(_ handler: (() -> Void)?) {
        hostFocusRequestHandler = handler
    }

    func reattach(toWorkspace workspaceId: UUID) {
        self.workspaceId = workspaceId
    }

    func attach(_ view: ApplicationCaptureView, token: UUID) {
        guard activeCaptureToken == token else {
            view.stopCapture()
            return
        }
        hostedView = view
        applyCaptureVisibility()
        fulfillPendingFocusIfPossible()
    }

    func detach(_ view: ApplicationCaptureView, token: UUID) {
        guard activeCaptureToken == token, hostedView === view else {
            view.stopCapture()
            return
        }
        view.teardown()
        hostedView = nil
        activeCaptureToken = nil
        captureVisibleInUI = false
        activeCaptureMountID = nil
    }

    func captureViewDidMoveToWindow(_ view: ApplicationCaptureView, token: UUID) {
        guard activeCaptureToken == token, hostedView === view else { return }
        fulfillPendingFocusIfPossible()
    }

    func updateCaptureState(
        _ state: ApplicationCaptureState,
        failureDetail: String? = nil,
        token: UUID
    ) {
        guard activeCaptureToken == token else { return }
        setCaptureState(state, failureDetail: failureDetail)
    }

    func setCaptureVisibleInUI(
        _ visible: Bool,
        view: ApplicationCaptureView
    ) {
        guard hostedView === view else { return }
        activeCaptureMountID = nil
        captureVisibleInUI = visible
        applyCaptureVisibility()
    }

    func updateCaptureViewMount(
        isVisibleInUI: Bool,
        allowsPointerInput: Bool,
        view: ApplicationCaptureView,
        mountID: UUID
    ) {
        guard hostedView === view else { return }
        activeCaptureMountID = mountID
        captureVisibleInUI = isVisibleInUI
        view.setInputOwnership(allowsPointerInput)
        applyCaptureVisibility()
    }

    func endCaptureViewMount(
        _ mountID: UUID,
        view: ApplicationCaptureView
    ) {
        guard hostedView === view, activeCaptureMountID == mountID else {
            return
        }
        activeCaptureMountID = nil
        captureVisibleInUI = false
        view.setInputOwnership(false)
        applyCaptureVisibility()
    }

    var captureEligibleForCurrentVisibility: Bool {
        captureVisibleInUI && (canvasRendering ?? true)
    }

    func setCanvasRendering(_ rendering: Bool?) {
        canvasRendering = rendering
        applyCaptureVisibility()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        searchIndexPurge(id)
        pickerTask?.cancel()
        pickerTask = nil
        pickerRequestID = UUID()
        pendingFocus = false
        stopHostedCapture()
        runtimeLease = nil
        displayTitleDidChange = nil
        hostFocusRequestHandler = nil
    }

    func focus() {
        pendingFocus = true
        fulfillPendingFocusIfPossible()
    }

    func unfocus() {
        pendingFocus = false
        hostedView?.releaseForwardedInputs()
        guard let hostedView,
              let window = hostedView.window,
              window.firstResponder === hostedView else { return }
        window.makeFirstResponder(nil)
    }

    func ownedFocusIntent(
        for responder: NSResponder,
        in window: NSWindow
    ) -> PanelFocusIntent? {
        guard
            let hostedView,
            hostedView.window === window,
            let responderView = responder as? NSView,
            responderView.window === window,
            responderView === hostedView || responderView.isDescendant(of: hostedView)
        else {
            return nil
        }
        return .panel
    }

    func yieldFocusIntent(
        _ intent: PanelFocusIntent,
        in window: NSWindow
    ) -> Bool {
        guard
            intent == .panel,
            let responder = window.firstResponder,
            ownedFocusIntent(for: responder, in: window) == intent
        else {
            return false
        }
        hostedView?.releaseForwardedInputs()
        return window.makeFirstResponder(nil)
    }

    func sendNamedKey(_ name: String) -> ApplicationNamedKeySendResult {
        guard let parsed = ApplicationCaptureView.parseNamedKey(name) else {
            return .unknownKey
        }
        guard let hostedView else {
            return .surfaceUnavailable
        }
        return hostedView.sendNamedKey(
            keyCode: parsed.keyCode,
            flags: parsed.flags
        )
    }

    func applicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease? {
        guard !isClosed else { return nil }
        if let runtimeLease {
            return runtimeLease
        }
        let lease = await runtime.acquireApplicationSurfaceLease()
        guard !isClosed else {
            lease?.release()
            return nil
        }
        runtimeLease = lease
        return lease
    }

    func retryCaptureAfterPermissions() {
        setCaptureState(
            captureEligibleForCurrentVisibility ? .starting : .suspended
        )
        applyCaptureVisibility()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func stopHostedCapture() {
        if let hostedView, let activeCaptureToken {
            detach(hostedView, token: activeCaptureToken)
        } else {
            hostedView?.teardown()
            hostedView = nil
            activeCaptureToken = nil
            captureVisibleInUI = false
            activeCaptureMountID = nil
        }
    }

    private func fulfillPendingFocusIfPossible() {
        guard pendingFocus, let hostedView, let window = hostedView.window else { return }
        guard window.makeFirstResponder(hostedView) else { return }
        pendingFocus = false
    }

    private func applyCaptureVisibility() {
        let captureEligible = captureEligibleForCurrentVisibility
        if !captureEligible, captureTarget != nil {
            switch captureState {
            case .starting, .streaming:
                setCaptureState(.suspended)
            case .suspended, .permissionRequired, .windowUnavailable, .failed:
                break
            }
        }
        hostedView?.setCaptureActive(Self.shouldRequestCaptureActivation(
            captureEligible: captureEligible,
            state: captureState
        ))
    }

    nonisolated static func shouldRequestCaptureActivation(
        captureEligible: Bool,
        state: ApplicationCaptureState
    ) -> Bool {
        guard captureEligible else { return false }
        switch state {
        case .starting, .streaming, .suspended:
            return true
        case .permissionRequired, .windowUnavailable, .failed:
            return false
        }
    }

    private func setCaptureState(
        _ state: ApplicationCaptureState,
        failureDetail: String? = nil
    ) {
        captureState = state
        captureRuntimeFailureDetail = state == .failed ? failureDetail : nil
    }
}
