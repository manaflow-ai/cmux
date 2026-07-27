import AppKit
import ApplicationServices
import Foundation
import Observation

/// A CMUX surface backed by a captured native application window.
@MainActor
@Observable
final class ApplicationPanel: Panel {
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
    let windowID: CGWindowID
    let processID: pid_t
    let targetFrameRate: Int
    private(set) var captureState: CaptureState = .starting

    private let title: String
    @ObservationIgnored
    private weak var hostedView: ApplicationCaptureView?
    @ObservationIgnored
    private var activeCaptureToken: UUID?
    @ObservationIgnored
    private var pendingFocus = false
    @ObservationIgnored
    private var captureVisibleInUI = false
    @ObservationIgnored
    private var canvasRendering = true

    var displayTitle: String { title }
    var displayIcon: String? { "macwindow" }
    var isCaptureViewInWindow: Bool { hostedView?.window != nil }
    var captureStateDescription: String {
        switch captureState {
        case .starting: "starting"
        case .streaming: "streaming"
        case .permissionRequired: "permission_required"
        case .windowUnavailable: "window_unavailable"
        case .failed: "failed"
        }
    }
    var captureFailureDetail: String? {
        captureState == .failed ? "capture_failed" : nil
    }

    init?(
        id: UUID = UUID(),
        workspaceId: UUID,
        windowID: CGWindowID,
        processID: pid_t,
        title: String,
        targetFrameRate: Int
    ) {
        guard windowID > 0, processID > 0, (1...120).contains(targetFrameRate) else {
            return nil
        }
        self.id = id
        self.workspaceId = workspaceId
        self.windowID = windowID
        self.processID = processID
        self.title = title
        self.targetFrameRate = min(max(targetFrameRate, 1), 120)
    }

    func beginCaptureSession() -> UUID {
        if let hostedView, let activeCaptureToken {
            detach(hostedView, token: activeCaptureToken)
        } else {
            hostedView?.stopCapture()
            hostedView = nil
            activeCaptureToken = nil
        }
        captureVisibleInUI = false
        canvasRendering = true
        let token = UUID()
        activeCaptureToken = token
        return token
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
        view.stopCapture()
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

    func setCaptureVisibleInUI(_ visible: Bool, token: UUID) {
        guard activeCaptureToken == token else { return }
        captureVisibleInUI = visible
        applyCaptureVisibility()
    }

    func setCanvasRendering(_ rendering: Bool) {
        canvasRendering = rendering
        applyCaptureVisibility()
    }

    func close() {
        pendingFocus = false
        if let hostedView, let activeCaptureToken {
            detach(hostedView, token: activeCaptureToken)
        } else {
            hostedView?.stopCapture()
            hostedView = nil
            activeCaptureToken = nil
            captureVisibleInUI = false
        }
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
        guard Self.hasLiveTarget(windowID: windowID, processID: processID),
              AXIsProcessTrusted(),
              let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: false
              ) else {
            return .surfaceUnavailable
        }
        down.flags = parsed.flags
        up.flags = parsed.flags
        down.postToPid(processID)
        up.postToPid(processID)
        return .sent
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func fulfillPendingFocusIfPossible() {
        guard pendingFocus, let hostedView, let window = hostedView.window else { return }
        guard window.makeFirstResponder(hostedView) else { return }
        pendingFocus = false
    }

    private func applyCaptureVisibility() {
        hostedView?.setCaptureActive(captureVisibleInUI && canvasRendering)
    }

    static func hasLiveTarget(windowID: CGWindowID, processID: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[String: Any]]
        guard let window = windows?.first,
              let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              pid_t(ownerPID) == processID,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary else {
            return false
        }
        var frame = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(bounds, &frame)
            && frame.width > 0
            && frame.height > 0
    }
}
