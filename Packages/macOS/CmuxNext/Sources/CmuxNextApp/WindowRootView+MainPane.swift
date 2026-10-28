import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import Observation

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
        if let window { NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window) }
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

extension WindowRootView {
    /// Follows the main pane tunables and the UI scale (the first emission
    /// applies the current values).
    func observeMainPane() -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in ObservationStream({ () -> [CGFloat] in [Metrics.mainPaneGutter, Metrics.mainPaneCornerRadius,
                                                Metrics.mainPaneChromeShade(isDark: false), Metrics.mainPaneChromeShade(isDark: true), Metrics.floatingPanes ? 1 : 0] }) {
                self?.applyMainPane()
            }
        }
    }

    /// Insets the content host by the gutter on every side (beside the
    /// sidebar, under the titlebar, from the window edges, also with the
    /// sidebar hidden or in fullscreen; 0, the flush opt-in, meets them),
    /// rounds it, and reshades the chrome.
    // @intent familiar first (Lawrence 2026-10-14): a margin on every side of the main pane, as in
    // Helium, the sidebar's side too.
    func applyMainPane() {
        let gutter = Metrics.mainPaneGutter, top = WindowTitlebar.cardTopInset(of: self, minimal: titlebarStyle == .minimal, gutter: gutter)
        // The right sidebar sits on the edge opposite the sidebar: on the left
        // side's pins it insets the trailing edge, on the right side's the leading one.
        let panel = rightPanelWidth
        for (side, constraints) in sidePins {
            for constraint in constraints where constraint.firstItem === contentHost {
                switch constraint.firstAttribute {
                case .leading: constraint.constant = gutter + (side == .right && constraint.secondItem === self ? panel : 0)
                case .trailing: constraint.constant = -gutter - (side == .left && constraint.secondItem === self ? panel : 0)
                default: break
                }
            }
        }
        for constraint in mainPaneEdges where constraint.firstItem === contentHost {
            switch constraint.firstAttribute { // the top as `updateMainPaneTopInset` sets it, so no pass shows the bare gutter
            case .top: constraint.constant = top
            case .bottom: constraint.constant = -gutter
            default: break
            }
        }
        applySidebarRail()
        needsLayout = true
        updateMainPaneShade()
    }

    /// The main pane's corner radius in this window: concentric with the
    /// window's own corners, which change with fullscreen.
    var mainPaneCornerRadius: CGFloat {
        Metrics.mainPaneCornerRadius(windowCornerRadius: window?.frameCornerRadius ?? 0)
    }

    /// Under a minimal titlebar the top row's pills sit on the traffic lights' line (`WindowTitlebar.cardTopInset`).
    func updateMainPaneTopInset() {
        let top = WindowTitlebar.cardTopInset(of: self, minimal: titlebarStyle == .minimal, gutter: Metrics.mainPaneGutter)
        for edge in mainPaneEdges where edge.firstItem === contentHost && edge.firstAttribute == .top && edge.constant != top { edge.constant = top }
    }

    /// Rounds the content host and redraws the shade around its current
    /// frame. A radius change alone moves no page, so Chromium pages are
    /// told to re-read their clip.
    func updateMainPaneShade() {
        let radius = presentsPage ? 0 : mainPaneCornerRadius
        if contentHost.setCornerRadius(radius), let window {
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
        }
        let alpha = Metrics.mainPaneChromeShade(isDark: themeTokens.isDark)
        mainPaneShade.update(card: contentHost.frame, radius: radius, alpha: alpha)
    }
}

// A fullscreen page with the whole window (`WindowController+FullScreen`):
// the content host leaves its side and edge pins for the window's edges, with
// no gutter or corners, and the chrome around it hides. The sidebar keeps its
// model state (shown, width), so nothing of it is saved or animated; leaving
// restores the pins and shows what it hid.
extension WindowRootView {
    /// Every side and edge pin of the content host (all sides: a side switch meanwhile swaps sets).
    var contentHostPins: [NSLayoutConstraint] {
        (sidePins.values.flatMap { $0 } + mainPaneEdges).filter { $0.firstItem === contentHost }
    }

    func applyPagePresentation() {
        if presentsPage {
            NSLayoutConstraint.deactivate(contentHostPins)
            NSLayoutConstraint.activate(pagePresentationPins)
            hidePagePresentationChrome()
            applyTokens()
        } else {
            NSLayoutConstraint.deactivate(pagePresentationPins)
            NSLayoutConstraint.activate((sidePins[sidebarSide] ?? []).filter { $0.firstItem === contentHost } + mainPaneEdges)
            applySidebarRail()
            for view in pagePresentationHidden { view.isHidden = false }
            pagePresentationHidden = []
            applyTokens() // the title row as the titlebar style says now
            applyMainPane()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateMainPaneShade()
        // The card's corners and edges moved without its pages moving: Chromium pages re-read their clip.
        if let window { NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window) }
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
