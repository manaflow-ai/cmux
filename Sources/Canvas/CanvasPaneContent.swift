import AppKit
import CmuxCanvasUI

/// How a panel's content view mounts into a canvas pane.
///
/// Terminals mount their real `GhosttySurfaceScrollView` directly (detached
/// from the window portal) so they keep full size at the viewport edge and
/// never reflow during panning. Other panel kinds keep their native views
/// inside a hosting view.
enum CanvasPaneContent {
    /// A terminal surface hosted directly as an AppKit subview.
    case terminal(TerminalPanel, SessionContentWidthPresentation)
    /// Any other panel kind, owned by the shared native panel controller.
    /// Carries the panel so the mount can drive panel-level lifecycle.
    case hosted(
        any Panel,
        PanelContentViewController,
        CanvasHostedPanelPresentation,
        PanelContentConfiguration
    )
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
    private var hostedConfiguration: PanelContentConfiguration?

    /// Mounts panel content into the pane's content container.
    ///
    /// - Parameters:
    ///   - content: What to mount.
    ///   - panelId: The panel this content belongs to.
    ///   - container: The pane view's content container.
    ///   - onFocusPanel: Invoked when the content reports keyboard focus
    ///     (terminal surfaces report via their `onFocus` hook).
    ///   - makeTerminalVisible: Applies terminal visibility after attaching
    ///     the terminal view to its container.
    init(
        content: CanvasPaneContent,
        panelId: UUID,
        container: NSView,
        onFocusPanel: @escaping (UUID) -> Void,
        makeTerminalVisible: @MainActor (GhosttySurfaceScrollView) -> Void = { $0.setVisibleInUI(true) }
    ) {
        self.content = content
        self.panelId = panelId
        self.container = container
        self.onFocusPanel = onFocusPanel

        let view: NSView
        switch content {
        case .terminal(let panel, let sessionContentWidthPresentation):
            let hostedView = panel.hostedView
            // The window portal resizes hosted terminals to their visible
            // intersection; on a scrolling canvas that would reflow the
            // terminal at the viewport edge. Detach and parent directly so
            // the clip view crops instead.
            TerminalWindowPortalRegistry.detach(hostedView: hostedView)
            hostedView.setSessionContentWidthPresentation(sessionContentWidthPresentation)
            hostedView.setFocusHandler { [weak self] in
                guard let self else { return }
                self.onFocusPanel?(self.panelId)
            }
            view = hostedView
        case .hosted(let panel, let controller, _, let configuration):
            hostedConfiguration = configuration
            view = controller.view
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
        case .terminal(let panel, _):
            Self.attachTerminalView(
                panel.hostedView,
                to: container,
                makeVisible: makeTerminalVisible
            )
        case .hosted:
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

    /// Attaches a terminal view before applying its visible lifecycle state.
    static func attachTerminalView<View: NSView>(
        _ view: View,
        to container: NSView,
        makeVisible: @MainActor (View) -> Void
    ) {
        // Ghostty's scroll view manages its own constraints-free layout.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        makeVisible(view)
    }

    /// The terminal panel when this mount hosts a terminal directly.
    var terminalPanel: TerminalPanel? {
        if case .terminal(let panel, _) = content { return panel }
        return nil
    }

    /// Applies host presentation state that changes while the direct-hosted
    /// terminal stays mounted.
    func updatePresentation(
        isFocused: Bool,
        isVisibleInUI: Bool,
        allowsPointerInput: Bool,
        showsInactiveOverlay: Bool,
        inactiveOverlayColor: NSColor,
        inactiveOverlayOpacity: Double,
        sessionContentWidthPresentation: SessionContentWidthPresentation
    ) {
        switch content {
        case .terminal(let panel, _):
            let hostedView = panel.hostedView
            hostedView.setSessionContentWidthPresentation(sessionContentWidthPresentation)
            hostedView.setActive(isFocused)
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
        case .hosted(_, let controller, let presentation, _):
            presentation.setFocused(isFocused)
            presentation.setAllowsPointerInput(allowsPointerInput)
            guard var configuration = hostedConfiguration else { return }
            configuration.isFocused = isFocused
            configuration.isVisibleInUI = isVisibleInUI
            configuration.allowsPointerInput = allowsPointerInput
            hostedConfiguration = configuration
            controller.update(configuration: configuration)
        }
    }

    /// Applies the explicit canvas lifecycle state to the mounted content.
    /// Offscreen terminals stop rendering (Ghostty occlusion) but keep their
    /// size, so re-entering the viewport never reflows.
    func setRendering(_ rendering: Bool) {
        switch content {
        case .terminal(let panel, _):
            panel.surface.setOcclusion(rendering)
        case .hosted(let panel, _, _, _):
            (panel as? SimulatorPanel)?.setCanvasRendering(rendering)
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
        case .terminal(let panel, _):
            let hostedView = panel.hostedView
            hostedView.setActive(false)
            hostedView.setFocusHandler(nil)
            hostedView.setInactiveOverlay(color: .clear, opacity: 0, visible: false)
            panel.surface.setOcclusion(true)
            hostedView.removeFromSuperview()
        case .hosted(let panel, let controller, _, _):
            if let simulatorPanel = panel as? SimulatorPanel {
                simulatorPanel.setVisibleInUI(false)
                simulatorPanel.setCanvasRendering(nil)
            }
            if let browserPanel = panel as? BrowserPanel {
                browserPanel.canvasInlineHostingActive = false
                browserPanel.noteWebViewVisibility(false, reason: "canvas.unmount")
            }
            controller.teardown()
            controller.view.removeFromSuperview()
        }
        hostedConfiguration = nil
        onFocusPanel = nil
    }
}
