import AppKit
import CmuxNextDesign

/// `ProgressView`: with a `value` (0 to 1), a thin bar across the width, the done part in the scope's
/// primary ink over a quiet track (AppKit's inactive grey while its window is not key; it repaints when
/// the window gains or loses key); without one, the shared themed spinner
/// (`StatusIndicatorView.spinner()`, the app's loading glyph and clock), 16 points.
final class AppSceneProgressNSView: AppSceneNodeNSView {
    private let track = CALayer()
    private let done = CALayer()
    private let spinner = StatusIndicatorView.spinner()
    private static let spinnerSide: CGFloat = 16
    private static let barHeight: CGFloat = 4
    /// AppKit's inactive progress bar fill: an opaque (170, 170, 170) in light and dark (measured on the
    /// SwiftUI bar this view replaced, controls-tour-full 2026-11-09).
    private static let inactiveInk = NSColor(srgbRed: 170.0 / 255, green: 170.0 / 255, blue: 170.0 / 255, alpha: 1) // colour-allow: AppKit's own inactive bar grey, the same in every theme, not a theme ink
    /// Repaints on the window's key changes (the done part's ink follows them).
    private lazy var keyRepaint = KeyWindowRepaint(self)

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        for bar in [track, done] {
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            bar.cornerRadius = Self.barHeight / 2
            layer?.addSublayer(bar)
        }
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    private var value: Double? { node.number("value").map { min(max($0, 0), 1) } }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        track.isHidden = value == nil
        done.isHidden = value == nil
        spinner.isHidden = value != nil
        spinner.spin(value == nil && window != nil)
        setAccessibilityValue(value)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spinner.spin(value == nil && window != nil)
        keyRepaint.track()
    }

    override var contentNaturalWidth: CGFloat? { value == nil ? Self.spinnerSide : nil }

    override func contentHeight(width: CGFloat) -> CGFloat { value == nil ? Self.spinnerSide : Self.barHeight }

    override func layoutContent(in rect: CGRect) {
        let bar = CGRect(x: rect.minX, y: rect.midY - Self.barHeight / 2, width: rect.width, height: Self.barHeight)
        track.frame = bar
        done.frame = CGRect(x: bar.minX, y: bar.minY, width: bar.width * (value ?? 0), height: bar.height)
        let side = Self.spinnerSide
        spinner.frame = CGRect(x: rect.minX, y: rect.midY - side / 2, width: side, height: side).integral
    }

    override func paint() {
        track.backgroundColor = Palette.hoverFill.cgColor
        done.backgroundColor = (window?.isKeyWindow == true ? Palette.textPrimary : Self.inactiveInk).cgColor
    }
}
