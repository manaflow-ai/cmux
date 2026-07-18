import AppKit
import CmuxTerminalRenderCompositor

/// Main-actor mounting state for one external terminal compositor.
@MainActor
final class TerminalBackendPresentationMount {
    let surfaceID: UUID

    private weak var hostView: NSView?
    private(set) var compositorView: TerminalRenderCompositorView?
    var onHostMounted: (@MainActor () -> Void)?

    var isMounted: Bool { hostView != nil }

    init(surfaceID: UUID) {
        self.surfaceID = surfaceID
    }

    func mount(in hostView: NSView) {
        if self.hostView !== hostView {
            compositorView?.removeFromSuperview()
            self.hostView = hostView
        }
        installCurrentViewIfNeeded()
        onHostMounted?()
    }

    func install(_ compositorView: TerminalRenderCompositorView) {
        if self.compositorView === compositorView { return }
        self.compositorView?.removeFromSuperview()
        self.compositorView = compositorView
        installCurrentViewIfNeeded()
    }

    func unmount(from hostView: NSView? = nil) {
        if let hostView, self.hostView !== hostView { return }
        compositorView?.removeFromSuperview()
        self.hostView = nil
    }

    func removeCompositor() {
        compositorView?.removeFromSuperview()
        compositorView = nil
    }

    func invalidate() {
        unmount()
        removeCompositor()
        onHostMounted = nil
    }

    private func installCurrentViewIfNeeded() {
        guard let hostView, let compositorView else { return }
        if compositorView.superview !== hostView {
            compositorView.removeFromSuperview()
            compositorView.frame = hostView.bounds
            compositorView.autoresizingMask = [.width, .height]
            hostView.addSubview(compositorView, positioned: .below, relativeTo: nil)
        }
        compositorView.frame = hostView.bounds
    }
}
