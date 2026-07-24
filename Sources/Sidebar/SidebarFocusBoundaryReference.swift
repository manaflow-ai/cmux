import AppKit

/// Tracks the AppKit rectangle occupied by the complete default sidebar so
/// focus handoff covers native rows and SwiftUI-hosted controls alike.
@MainActor
final class SidebarFocusBoundaryReference {
    private weak var boundaryView: NSView?

    func attach(_ view: NSView) {
        boundaryView = view
    }

    func contains(_ responder: NSResponder, in window: NSWindow) -> Bool {
        guard let boundaryView,
              boundaryView.window === window,
              let responderView = Self.responderView(responder),
              responderView.window === window else {
            return false
        }
        let boundaryFrame = boundaryView.convert(boundaryView.bounds, to: nil)
        let responderFrame = responderView.convert(responderView.visibleRect, to: nil)
        guard !boundaryFrame.isEmpty, !responderFrame.isEmpty else { return false }
        return boundaryFrame.contains(NSPoint(x: responderFrame.midX, y: responderFrame.midY))
    }

    private static func responderView(_ responder: NSResponder) -> NSView? {
        if let editor = responder as? NSTextView,
           let delegateView = editor.delegate as? NSView {
            return delegateView
        }
        return responder as? NSView
    }
}
