import AppKit
import Foundation
import Observation

/// A cmux pane that selects, captures, and controls one native application window.
@MainActor
@Observable
final class ApplicationPanel: Panel {
    struct CaptureTarget: Equatable {
        let windowID: CGWindowID
        let processID: pid_t
    }

    enum CaptureState: Equatable {
        case starting
        case streaming
        case permissionRequired
        case windowUnavailable
        case failed
    }

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .application
    let workspaceId: UUID
    let targetFrameRate: Int
    let runtime: any ApplicationSurfaceRuntime
    @ObservationIgnored
    let pickerModel = ApplicationSurfacePickerModel()

    private(set) var windowID: CGWindowID?
    private(set) var processID: pid_t?
    private(set) var captureState: CaptureState = .starting
    private(set) var captureGeneration = UUID()

    private var targetTitle: String?
    @ObservationIgnored
    private var hostedView: ApplicationCaptureView?
    @ObservationIgnored
    private var activeCaptureToken: UUID?
    @ObservationIgnored
    private var pendingFocus = false
    @ObservationIgnored
    private var captureVisibleInUI = false
    @ObservationIgnored
    private var canvasRendering = true
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

    var captureTarget: CaptureTarget? {
        guard let windowID, let processID else { return nil }
        return CaptureTarget(windowID: windowID, processID: processID)
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
        case .permissionRequired: return "permission_required"
        case .windowUnavailable: return "window_unavailable"
        case .failed: return "failed"
        }
    }
    var captureFailureDetail: String? {
        if case .failed(let detail) = pickerModel.phase {
            return detail
        }
        return captureState == .failed ? "capture_failed" : nil
    }

    init?(
        id: UUID = UUID(),
        workspaceId: UUID,
        windowID: CGWindowID? = nil,
        processID: pid_t? = nil,
        title: String? = nil,
        targetFrameRate: Int,
        runtime: any ApplicationSurfaceRuntime,
        runtimeLease: ApplicationSurfaceRuntimeLease? = nil
    ) {
        guard (1...120).contains(targetFrameRate) else { return nil }
        guard (windowID == nil) == (processID == nil) else { return nil }
        if let windowID, let processID {
            guard windowID > 0, processID > 0 else { return nil }
        }

        self.id = id
        self.workspaceId = workspaceId
        self.windowID = windowID
        self.processID = processID
        targetTitle = title
        self.targetFrameRate = min(max(targetFrameRate, 1), 120)
        self.runtime = runtime
        self.runtimeLease = runtimeLease
        if windowID == nil {
            captureState = .starting
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
                self.pickerModel.phase = .failed(error.localizedDescription)
            }
        }
    }

    func selectWindow(_ window: ApplicationWindowDescriptor) {
        guard !isClosed, window.windowID > 0, window.processID > 0 else { return }
        pickerTask?.cancel()
        pickerTask = nil
        pickerRequestID = UUID()
        stopHostedCapture()
        windowID = CGWindowID(window.windowID)
        processID = pid_t(window.processID)
        targetTitle = window.title
        displayTitleDidChange?(displayTitle)
        pickerModel.selectedWindowID = window.windowID
        captureState = .starting
        captureGeneration = UUID()
    }

    func chooseAnotherWindow() {
        guard !isClosed else { return }
        stopHostedCapture()
        windowID = nil
        processID = nil
        targetTitle = nil
        displayTitleDidChange?(displayTitle)
        captureState = .starting
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
            onStateChanged: { [weak self] state in
                self?.updateCaptureState(state, token: captureToken)
            },
            onMovedToWindow: { [weak self] view in
                self?.captureViewDidMoveToWindow(view, token: captureToken)
            }
        )
        attach(view, token: captureToken)
        return view
    }

    func setDisplayTitleChangeHandler(_ handler: @escaping (String) -> Void) {
        displayTitleDidChange = handler
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
    }

    func captureViewDidMoveToWindow(_ view: ApplicationCaptureView, token: UUID) {
        guard activeCaptureToken == token, hostedView === view else { return }
        fulfillPendingFocusIfPossible()
    }

    func updateCaptureState(_ state: CaptureState, token: UUID) {
        guard activeCaptureToken == token else { return }
        captureState = state
    }

    func setCaptureVisibleInUI(
        _ visible: Bool,
        view: ApplicationCaptureView
    ) {
        guard hostedView === view else { return }
        captureVisibleInUI = visible
        applyCaptureVisibility()
    }

    func setCanvasRendering(_ rendering: Bool) {
        canvasRendering = rendering
        applyCaptureVisibility()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pickerTask?.cancel()
        pickerTask = nil
        pickerRequestID = UUID()
        pendingFocus = false
        stopHostedCapture()
        runtimeLease = nil
        displayTitleDidChange = nil
    }

    func focus() {
        pendingFocus = true
        fulfillPendingFocusIfPossible()
    }

    func unfocus() {
        pendingFocus = false
        guard let hostedView,
              let window = hostedView.window,
              window.firstResponder === hostedView else { return }
        window.makeFirstResponder(nil)
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
        captureState = .starting
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
        }
    }

    private func fulfillPendingFocusIfPossible() {
        guard pendingFocus, let hostedView, let window = hostedView.window else { return }
        guard window.makeFirstResponder(hostedView) else { return }
        pendingFocus = false
    }

    private func applyCaptureVisibility() {
        hostedView?.setCaptureActive(captureVisibleInUI && canvasRendering)
    }
}
