import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextWakeups

/// The window's content host as the curved main pane (cx-rkgu): a rounded
/// clip around the workspace content. Corners are circular (not
/// continuous) so the Chromium page mask, built from this layer's radius
/// (`CEFClipShape.clips(around:)`), matches them exactly, as for
/// `PaneClipView`. `masksToBounds` clips terminals (IOSurface and Metal
/// layers) and web views; Chromium pages are child windows and clip
/// through that mask.
final class MainPaneCardView: NSView {
    /// Called after the frame moves or resizes (the sidebar's animation
    /// moves it every frame), so the chrome shade follows in the same pass.
    var onFrameChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .circular
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onFrameChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameChange?()
    }

    /// Takes workspaces hidden past a grace out of the card (feature `hiddenWorkspaceDetachAfterGrace`);
    /// nil hides only: a hidden workspace stays here, withdrawn hidden, until its
    /// controller tears it down.
    var hiddenDetach: HiddenWorkspaceDetach? {
        didSet { hiddenDetach?.host = self }
    }

    /// A workspace view here hid or showed (`WorkspaceContentView.isHidden`): a hide starts its grace, a show
    /// ends it, whether a switch (`WindowRootView.show`) or the side-by-side view (`arrangeOnScreen`) set it.
    func workspaceDidChangeHidden(_ view: NSView) {
        guard let hiddenDetach else { return }
        if view.isHidden { hiddenDetach.didHide(view) } else { hiddenDetach.willShow(view) }
    }

    /// Places the workspaces a window shows side by side in these bounds (`WindowController.arrangeOnScreen`, Debug
    /// Settings `sidebar.multiView`), now and after every resize; nil while one workspace fills the host by its
    /// autoresizing mask.
    var arrangeContent: ((CGRect) -> Void)? {
        didSet { arrangeContent?(bounds) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if let held = heldContentFrame { return placeContent(in: held) }
        super.resizeSubviews(withOldSize: oldSize)
        arrangeContent?(bounds)
    }

    /// One width for the content through a sidebar slide (`WindowRootView+ContentAreaMotion`):
    /// the wider of its start and its landing, so a pane, terminal or page lays out once instead
    /// of on every frame. The content rides the card's edge that moves (the sidebar's side) and the
    /// card clips it at the other; nil at rest, and clearing it fits the content to the card again.
    struct ContentHold: Equatable {
        var width: CGFloat
        /// The sidebar is on the right, so the card's trailing edge moves and the content rides it.
        var ridesTrailingEdge: Bool
    }

    var contentHold: ContentHold? {
        didSet {
            guard contentHold != oldValue else { return }
            applyClip()
            if let held = heldContentFrame {
                placeContent(in: held)
            } else if oldValue != nil {
                placeContent(in: bounds)
                arrangeContent?(bounds)
            }
        }
    }

    /// Where the held content sits in the card; nil at rest. Several workspaces side by side
    /// (`arrangeContent`) are placed by their own arrangement and never held.
    var heldContentFrame: CGRect? {
        guard let contentHold, arrangeContent == nil else { return nil }
        let width = max(bounds.width, contentHold.width)
        return CGRect(x: contentHold.ridesTrailingEdge ? bounds.width - width : 0, y: 0, width: width, height: bounds.height)
    }

    /// Whether the card clips its content: when rounded, and while it holds content wider than
    /// itself, a square card too. That clip is what Chromium pages (`CEFClipShape.clips(around:)`) and
    /// the window overlay's rings (`OverlayPlane.roundedClip`) read for the card's edge.
    private var clips: Bool { (layer?.cornerRadius ?? 0) > 0 || contentHold != nil }

    /// Applies `clips`; returns whether it changed. A clip that comes or goes moves no page, so
    /// Chromium pages are told to re-read their clip shape.
    @discardableResult
    private func applyClip() -> Bool {
        guard let layer, layer.masksToBounds != clips else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = clips
        CATransaction.commit()
        window?.updateBrowserPageGeometry()
        return true
    }

    /// The content fills `rect`: what `show` sized to the card and left to the autoresizing mask.
    /// A workspace withdrawn hidden has no mask and keeps its frame.
    private func placeContent(in rect: CGRect) {
        for view in subviews where view.autoresizingMask.contains(.width) && view.frame != rect {
            view.frame = rect
        }
    }

    /// Returns whether the radius or the clip changed. Square (0) does not clip at rest, so the
    /// flat pane behaves exactly as before the curved one existed.
    @discardableResult
    func setCornerRadius(_ radius: CGFloat) -> Bool {
        guard let layer else { return false }
        var changed = false
        if layer.cornerRadius != radius {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = radius
            CATransaction.commit()
            changed = true
        }
        return applyClip() || changed
    }
}

extension MainPaneCardView: HiddenWorkspaceDetachHost {
    func holdsHidden(_ workspace: AnyObject) -> Bool {
        guard let view = workspace as? NSView else { return false }
        return view.superview === self && view.isHidden
    }

    func detach(_ workspace: AnyObject) {
        guard let view = workspace as? NSView, view.superview === self, view.isHidden else { return }
        view.removeFromSuperview()
    }
}

extension WindowRootView {
    /// Follows the main pane tunables and the UI scale while `node` shows (the first value applies
    /// the current ones).
    func observeMainPane(on node: VisibilityNode, work: MainWorkScheduler) -> VisibleObservation<[CGFloat]> {
        VisibleObservation(node, owner: "WindowRootView.mainPane", on: work) { () -> [CGFloat] in
            [Metrics.mainPaneGutter, Metrics.mainPaneCornerRadius, Metrics.mainPaneChromeShade(isDark: false),
             Metrics.mainPaneChromeShade(isDark: true), Metrics.floatingPanes ? 1 : 0]
        } apply: { [weak self] _ in
            self?.applyMainPane()
        }
    }

    /// Insets the content host by the gutter on every side (beside the
    /// sidebar, under the titlebar, from the window edges, also with the
    /// sidebar hidden or in fullscreen; 0, the flush opt-in, meets them),
    /// rounds it, and reshades the chrome.
    // @intent familiar first (Lawrence 2026-10-14): a margin on every side of the main pane, as in
    // Helium, the sidebar's side too.
    func applyMainPane() {
        needsLayout = true // invalidate: the callers moved the gutter, the right panel, the rail or the titlebar inset.
        updateMainPaneShade()
    }

    /// The main pane's corner radius in this window: concentric with the
    /// window's own corners, which change with fullscreen.
    var mainPaneCornerRadius: CGFloat {
        Metrics.mainPaneCornerRadius(windowCornerRadius: window?.frameCornerRadius ?? 0)
    }

    /// What `layout()` frames the main pane and the titlebar from, now. Under a minimal titlebar the
    /// top row's pills sit on the traffic lights' line (`WindowTitlebar.cardTopInset`); the right
    /// sidebar sits on the edge opposite the sidebar.
    var mainPaneLayoutInput: WindowRootLayout.Input {
        let minimal = titlebarStyle == .minimal, gutter = Metrics.mainPaneGutter
        return WindowRootLayout.Input(
            bounds: bounds, sidebarFrame: sidebar.frame, side: sidebarSide, railInset: railContentInset, gutter: gutter,
            cardTopInset: WindowTitlebar.cardTopInset(of: self, minimal: minimal, gutter: gutter),
            titlebarHeight: minimal ? 0 : Metrics.titlebarHeight, rightPanelWidth: rightPanelWidth,
            trafficLightInset: Metrics.trafficLightInset
        )
    }

    /// Frames the main pane and the titlebar for this pass (`WindowRootLayout`), on the backing pixel
    /// grid as Auto Layout placed them. Each frame is set only when it changed: a card that did not
    /// move resizes no pane.
    func layoutMainPaneAndTitle() {
        let frames = WindowRootLayout(mainPaneLayoutInput)
        // A fullscreen page has the whole window: the card fills it, with no gutter (`presentsPage`).
        let content = presentsPage ? bounds : backingAlignedRect(frames.content, options: .alignAllEdgesNearest)
        let title = backingAlignedRect(frames.titlebar, options: .alignAllEdgesNearest)
        if titlebar.frame != title { titlebar.frame = title }
        if contentHost.frame != content { contentHost.frame = content }
    }

    /// Rounds the content host and redraws the shade around its current
    /// frame. A radius change alone moves no page, so Chromium pages are
    /// told to re-read their clip.
    func updateMainPaneShade() {
        let radius = presentsPage ? 0 : mainPaneCornerRadius
        if contentHost.setCornerRadius(radius) { window?.updateBrowserPageGeometry() }
        let alpha = Metrics.mainPaneChromeShade(isDark: themeTokens.isDark)
        mainPaneShade.update(card: contentHost.frame, radius: radius, alpha: alpha)
    }
}

// A fullscreen page with the whole window (`WindowController+FullScreen`):
// the content host fills the window (`layoutMainPaneAndTitle`), with no
// gutter or corners, and the chrome around it hides. The sidebar keeps its
// model state (shown, width), so nothing of it is saved or animated; leaving
// frames the card beside the sidebar again and shows what it hid.
extension WindowRootView {
    func applyPagePresentation() {
        if presentsPage {
            hidePagePresentationChrome()
            applyTokens()
        } else {
            applySidebarRail()
            for view in pagePresentationHidden { view.isHidden = false }
            pagePresentationHidden = []
            applyTokens() // the title row as the titlebar style says now
        }
        // invalidate: the card's frame and corners change; the window's next layout frames it, reshades it and,
        // when its corners change, has Chromium pages re-read their clip (`updateMainPaneShade`).
        applyMainPane()
    }

    /// Hides the chrome around the content host, remembering the views it hid (one hidden on its own stays so).
    func hidePagePresentationChrome() {
        // The title row (`applyTokens`), the right sidebar and the titlebar badge (layout) follow
        // `presentsPage` themselves; the host pressure warning stays (it shows only under pressure).
        for view in [sidebar, toolbarBand, trafficLightsGlass, titlebarRevealRegion, mainPaneShade] as [NSView] where !view.isHidden {
            pagePresentationHidden.append(view)
            view.isHidden = true
        }
    }
}
