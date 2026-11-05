import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import Observation

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
        goo.update() // follows the card on every frame of a slide; a page or a style change turns it on or off
    }
}

extension WindowRootView: GooWindowHost {
    var gooSidebar: (any GooSidebarSource)? { sidebar }
    var gooSidebarOnLeft: Bool { sidebarSide != .right }
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
