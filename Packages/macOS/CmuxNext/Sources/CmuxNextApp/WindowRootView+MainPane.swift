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

    /// Returns whether the radius changed. Square (0) does not clip, so the
    /// flat pane behaves exactly as before the curved one existed.
    @discardableResult
    func setCornerRadius(_ radius: CGFloat) -> Bool {
        guard let layer, layer.cornerRadius != radius || layer.masksToBounds != (radius > 0) else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        layer.masksToBounds = radius > 0
        CATransaction.commit()
        return true
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

    /// The content host's edge constraints: top and bottom, and the
    /// content's side pins of both sidebar sides.
    var mainPaneInsetConstraints: [NSLayoutConstraint] {
        (mainPaneEdges + sidePins.values.flatMap { $0 }).filter { $0.firstItem === contentHost }
    }

    /// Rounds the content host and redraws the shade around its current
    /// frame. A radius change alone moves no page, so Chromium pages are
    /// told to re-read their clip.
    func updateMainPaneShade() {
        let radius = mainPaneCornerRadius
        if contentHost.setCornerRadius(radius), let window {
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
        }
        let alpha = Metrics.mainPaneChromeShade(isDark: themeTokens.isDark)
        mainPaneShade.update(card: contentHost.frame, radius: radius, alpha: alpha)
    }
}
