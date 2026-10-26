import AppKit
import CmuxNextDesign
import QuartzCore

/// What a page shows from its cold open's turn until its first frame (``PageWebView/showStandIn(title:)``):
/// the page's own background (`--cmux-surface-background`, the color its `<html>` paints) with its title,
/// so the pane is the page's from the open's frame on (feature `pageStandIn`).
///
/// Chromium paints a page's base background color in the view's layer until the renderer's first
/// frame (content/browser/renderer_host/render_widget_host_view_mac.mm, `SetBackgroundColor`), and changes
/// that layer with Core Animation actions off (ui/base/cocoa/animation_utils.h, `ScopedCAActionDisabler`).
/// This layer and its title never animate: neither has an action for any key, so no add, remove,
/// frame or color change starts one, inside an animation group or not (p13-webui.md 4.5).
nonisolated final class PageStandInLayer: CALayer {
    /// The title, centered, in the type scale's title size and weight.
    let title = ChromeTextLayer()

    override init() {
        super.init()
        // The title's own actions: every key the stand-in changes on it is still.
        title.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
                         "contentsScale": NSNull(), "hidden": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        title.alignmentMode = .center
        title.truncation = .end
        addSublayer(title)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// No implicit animation for any key (not even `onOrderIn` and `onOrderOut`): the stand-in comes and
    /// goes in one frame.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Colors from `theme`, the title `text` at the page's `zoom` (its own text is zoomed by it), drawn
    /// at the window's backing `scale`.
    func paint(_ theme: WebTheme, title text: String, zoom: Double, scale: CGFloat) {
        Self.withoutActions {
            backgroundColor = theme.variables["--cmux-surface-background"].flatMap(Self.color(css:))
            title.foregroundColor = theme.variables["--cmux-text-secondary"].flatMap(Self.color(css:))
            title.string = text
            title.font = .systemFont(ofSize: TypeScale.title * CGFloat(zoom), weight: TypeScale.emphasis)
            title.contentsScale = scale
            setNeedsLayout()
        }
    }

    /// The least room beside a long title; past it the title ends in an ellipsis.
    private static let sideInset: CGFloat = 16

    override func layoutSublayers() {
        super.layoutSublayers()
        Self.withoutActions {
            let font = title.font
            let height = ceil(font.ascender - font.descender)
            let width = max(0, min(ceil(title.textWidth), bounds.width - 2 * Self.sideInset))
            title.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                                 width: width, height: height)
        }
    }

    /// `rgba(r, g, b, a)` with 0-255 channels (``WebTheme/css(_:)``'s form) as a color; nil for anything else.
    static func color(css: String) -> CGColor? {
        guard css.hasPrefix("rgba("), css.hasSuffix(")") else { return nil }
        let values = css.dropFirst(5).dropLast().split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard values.count == 4 else { return nil }
        return CGColor(srgbRed: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: values[3])
    }

    /// Runs `body` with Core Animation actions off (Chromium's `ScopedCAActionDisabler`).
    static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
