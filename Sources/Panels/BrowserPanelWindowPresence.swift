import AppKit
import SwiftUI

/// Whether a browser panel view is in a window
/// (https://github.com/manaflow-ai/cmux/issues/15069).
///
/// Memory Saver discards a hidden pane from its visibility reports, so a pane
/// counts as visible only while one of its views is in a window. SwiftUI can
/// build a browser view that never reaches a window and then dismantle it; a
/// visible report from that view would leave a hidden pane marked visible, and
/// Memory Saver would never discard it. The view sends its reports through
/// this object, which drops a visible report while the view's probe is outside
/// a window. The probe reports visible when it enters one.
@MainActor
final class BrowserPanelWindowPresence {
    fileprivate weak var probeView: BrowserPanelWindowPresenceView?

    var isInWindow: Bool {
        probeView?.window != nil
    }

    func noteVisibility(_ isVisible: Bool, of panel: BrowserPanel, reason: String) {
        guard !isVisible || isInWindow else { return }
        panel.noteWebViewVisibility(isVisible, reason: reason)
    }
}

/// An empty view in the browser panel's background that tracks its window.
struct BrowserPanelWindowPresenceProbe: NSViewRepresentable {
    let presence: BrowserPanelWindowPresence
    let panel: BrowserPanel
    /// Whether the panel view is shown and owns its pane.
    let isVisible: Bool

    func makeNSView(context: Context) -> BrowserPanelWindowPresenceView {
        BrowserPanelWindowPresenceView()
    }

    func updateNSView(_ nsView: BrowserPanelWindowPresenceView, context: Context) {
        presence.probeView = nsView
        let panel = panel
        nsView.onLeaveWindow = {
            panel.noteWebViewVisibility(false, reason: "view.leftWindow")
        }
        guard isVisible else {
            nsView.onEnterWindow = nil
            nsView.onLeaveWindow = nil
            return
        }
        nsView.onEnterWindow = {
            panel.noteWebViewVisibility(true, reason: "view.enteredWindow")
        }
    }
}

// SwiftUI/AppKit owns this probe on the main thread, but its lifecycle and
// hit-test callbacks can arrive without Swift's MainActor executor token.
final class BrowserPanelWindowPresenceView: NSView {
    var onEnterWindow: (() -> Void)?
    var onLeaveWindow: (() -> Void)?

    nonisolated override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            onLeaveWindow?()
            return
        }
        // Report after the AppKit move and any SwiftUI update around it finish,
        // using the latest callback, since a report can restore the page.
        Task { @MainActor [weak self] in
            guard let self, self.window != nil else { return }
            self.onEnterWindow?()
        }
    }

    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
