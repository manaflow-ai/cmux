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

/// The shade over the chrome around the curved main pane: the window minus
/// the pane's rounded rect, filled with black at a low alpha. It sits on
/// the window's one backdrop, under the sidebar and the titlebar (both
/// clear), so they and the gutter read as chrome and the pane as a card,
/// over an opaque or a translucent window alike. Takes no clicks.
final class MainPaneChromeShadeView: NSView {
    private let shade = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shade.fillRule = .evenOdd
        layer?.addSublayer(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shades everything but `card` (this view's coordinates); no shade when
    /// `alpha` is 0.
    func update(card: CGRect, radius: CGFloat, alpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        shade.frame = bounds
        guard alpha > 0, !card.isEmpty else {
            shade.path = nil
            return
        }
        let path = CGMutablePath()
        path.addRect(bounds)
        let corner = min(radius, card.width / 2, card.height / 2)
        path.addRoundedRect(in: card, cornerWidth: corner, cornerHeight: corner)
        shade.path = path
        shade.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }
}

extension WindowRootView {
    /// Follows the main pane tunables and the UI scale (the first emission
    /// applies the current values).
    func observeMainPane() -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in ObservationStream({ [Metrics.mainPaneGutter, Metrics.mainPaneCornerRadius,
                                                Metrics.mainPaneChromeShade(isDark: false), Metrics.mainPaneChromeShade(isDark: true)] }) {
                self?.applyMainPane()
            }
        }
    }

    /// Insets the content host by the gutter on every side (beside the
    /// sidebar, under the titlebar, from the window edges, also with the
    /// sidebar hidden or in fullscreen), rounds it, and reshades the chrome.
    /// A radius change alone moves no page, so Chromium pages are told to
    /// re-read their clip.
    func applyMainPane() {
        let gutter = Metrics.mainPaneGutter
        for constraint in mainPaneInsetConstraints {
            switch constraint.firstAttribute {
            case .leading, .top: constraint.constant = gutter
            case .trailing, .bottom: constraint.constant = -gutter
            default: break
            }
        }
        if contentHost.setCornerRadius(Metrics.mainPaneCornerRadius), let window {
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
        }
        needsLayout = true
        updateMainPaneShade()
    }

    /// The content host's edge constraints: top and bottom, and the
    /// content's side pins of both sidebar sides.
    var mainPaneInsetConstraints: [NSLayoutConstraint] {
        (mainPaneEdges + sidePins.values.flatMap { $0 }).filter { $0.firstItem === contentHost }
    }

    /// Redraws the shade around the content host's current frame.
    func updateMainPaneShade() {
        let alpha = Metrics.mainPaneChromeShade(isDark: themeTokens.isDark)
        mainPaneShade.update(card: contentHost.frame, radius: Metrics.mainPaneCornerRadius, alpha: alpha)
    }
}
