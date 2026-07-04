import AppKit
import CmuxCanvasUI

/// How a panel's content view mounts into a canvas pane.
///
/// Terminals mount their real `GhosttySurfaceScrollView` directly (detached
/// from the window portal) so they keep full size at the viewport edge and
/// never reflow during panning. Other panel kinds keep their SwiftUI views
/// inside a hosting view.
enum CanvasPaneContent {
    /// A terminal surface hosted directly as an AppKit subview.
    case terminal(TerminalPanel)
    /// Any other panel kind, hosted through an `NSHostingView`. Carries the
    /// panel so the mount can drive panel-level lifecycle (browser webview
    /// visibility / hidden-discard restore).
    case hosted(any Panel, NSView)
}

/// Owns the mounted content of one canvas pane and its teardown. This is the
/// app-side witness of the `CmuxCanvasUI` content seam: the package drives
/// lifecycle through ``CanvasPaneContentMounting`` without seeing panel
/// types.
@MainActor
final class CanvasPaneContentMount: CanvasPaneContentMounting {
    let panelId: UUID
    private let content: CanvasPaneContent
    private weak var container: NSView?
    private var onFocusPanel: ((UUID) -> Void)?

    /// Mounts panel content into the pane's content container.
    ///
    /// - Parameters:
    ///   - content: What to mount.
    ///   - panelId: The panel this content belongs to.
    ///   - container: The pane view's content container.
    ///   - onFocusPanel: Invoked when the content reports keyboard focus
    ///     (terminal surfaces report via their `onFocus` hook).
    init(
        content: CanvasPaneContent,
        panelId: UUID,
        container: NSView,
        onFocusPanel: @escaping (UUID) -> Void
    ) {
        self.content = content
        self.panelId = panelId
        self.container = container
        self.onFocusPanel = onFocusPanel

        let view: NSView
        switch content {
        case .terminal(let panel):
            let hostedView = panel.hostedView
            // The window portal resizes hosted terminals to their visible
            // intersection; on a scrolling canvas that would reflow the
            // terminal at the viewport edge. Detach and parent directly so
            // the clip view crops instead.
            TerminalWindowPortalRegistry.detach(hostedView: hostedView)
            hostedView.setVisibleInUI(true)
            hostedView.setActivePaneBoundary(visible: false, color: .clear)
            hostedView.setFocusHandler { [weak self] in
                guard let self else { return }
                self.onFocusPanel?(self.panelId)
            }
            view = hostedView
        case .hosted(let panel, let hostedView):
            view = hostedView
            // Canvas drives panel-level webview lifecycle: mounting makes the
            // browser visible (and restores a hidden-discarded webview), and
            // marks the webview inline-hosted so portal reconcilers leave it
            // to the pane hierarchy.
            if let browserPanel = panel as? BrowserPanel {
                browserPanel.canvasInlineHostingActive = true
                browserPanel.noteWebViewVisibility(true, reason: "canvas.mount")
            }
        }

        switch content {
        case .terminal:
            // Ghostty's scroll view manages its own constraints-free layout.
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.width, .height]
            view.frame = container.bounds
            container.addSubview(view)
        case .hosted:
            // Hosting views self-size to SwiftUI's ideal size under
            // autoresizing; pin with constraints so the pane dictates size.
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }

    /// The terminal panel when this mount hosts a terminal directly.
    var terminalPanel: TerminalPanel? {
        if case .terminal(let panel) = content { return panel }
        return nil
    }

    /// Applies host presentation state that changes while the direct-hosted
    /// terminal stays mounted.
    func updatePresentation(
        isFocused: Bool,
        showsInactiveOverlay: Bool,
        inactiveOverlayColor: NSColor,
        inactiveOverlayOpacity: Double
    ) {
        switch content {
        case .terminal(let panel):
            let hostedView = panel.hostedView
            hostedView.setActive(isFocused)
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
            hostedView.setActivePaneBoundary(visible: false, color: .clear)
        case .hosted:
            break
        }
    }

    /// Applies the explicit canvas lifecycle state to the mounted content.
    /// Offscreen terminals stop rendering (Ghostty occlusion) but keep their
    /// size, so re-entering the viewport never reflows.
    func setRendering(_ rendering: Bool) {
        switch content {
        case .terminal(let panel):
            panel.surface.setOcclusion(rendering)
        case .hosted(let panel, _):
            // Offscreen browsers may hidden-discard their webview; coming
            // back into the render region restores it.
            (panel as? BrowserPanel)?.noteWebViewVisibility(
                rendering,
                reason: rendering ? "canvas.render" : "canvas.occlude"
            )
        }
    }

    /// Unmounts the content. Terminals hand their view back to the portal
    /// system (the split layout's representable rebinds on its next update).
    func unmount() {
        switch content {
        case .terminal(let panel):
            let hostedView = panel.hostedView
            hostedView.setActive(false)
            hostedView.setFocusHandler(nil)
            hostedView.setInactiveOverlay(color: .clear, opacity: 0, visible: false)
            hostedView.setActivePaneBoundary(visible: false, color: .clear)
            panel.surface.setOcclusion(true)
            hostedView.removeFromSuperview()
        case .hosted(let panel, let view):
            if let browserPanel = panel as? BrowserPanel {
                browserPanel.canvasInlineHostingActive = false
                browserPanel.noteWebViewVisibility(false, reason: "canvas.unmount")
            }
            view.removeFromSuperview()
        }
        onFocusPanel = nil
    }
}
