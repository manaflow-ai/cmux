import AppKit
import Combine
import Foundation

/// A CMUX surface backed by a captured native application window.
@MainActor
final class ApplicationPanel: Panel, ObservableObject {
    enum CaptureState: Equatable {
        case starting
        case streaming
        case permissionRequired
        case windowUnavailable
        case failed(String)
    }

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .application
    let workspaceId: UUID
    let windowID: CGWindowID
    let processID: pid_t
    let targetFrameRate: Int
    @Published private(set) var captureState: CaptureState = .starting

    private let title: String
    private weak var hostedView: ApplicationCaptureView?
    private var activeCaptureToken: UUID?

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
        if case let .failed(detail) = captureState {
            return String(detail.prefix(512))
        }
        return nil
    }

    init?(
        id: UUID = UUID(),
        workspaceId: UUID,
        windowID: CGWindowID,
        processID: pid_t,
        title: String,
        targetFrameRate: Int
    ) {
        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[String: Any]]
        guard let ownerPID = windows?.first?[kCGWindowOwnerPID as String] as? Int,
              pid_t(ownerPID) == processID
        else {
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
        hostedView?.stopCapture()
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
    }

    func updateCaptureState(_ state: CaptureState, token: UUID) {
        guard activeCaptureToken == token else { return }
        captureState = state
    }

    func close() {
        activeCaptureToken = nil
        hostedView?.stopCapture()
    }

    func focus() {
        hostedView?.window?.makeFirstResponder(hostedView)
    }

    func unfocus() {}

    func sendNamedKey(_ name: String) -> Bool {
        hostedView?.sendNamedKey(name) ?? false
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
