import AppKit
import CmuxNextDesign

/// `Stat` (RFD 0009 slice 4): its `value` in the numeral role (34 points semibold), and
/// under it a 12 point caption: the `label` in secondary and the `delta`, after an arrow for its
/// `trend`, in success when the trend is the good one (`up` unless `goodTrend` is `down`), danger when
/// it is not, secondary when flat. Prominent draws the value in the accent, subtle in secondary.
/// webviews' `SceneStat` draws the same.
final class AppSceneStatNSView: AppSceneNodeNSView {
    private let value = ChromeLabel(labelWithString: "")
    private let label = ChromeLabel(labelWithString: "")
    private let delta = ChromeLabel(labelWithString: "")
    private static let captionGap: CGFloat = 6
    private static let lineGap: CGFloat = 2

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        value.font = Typography.system(size: Self.numeralSize, weight: TypeScale.emphasis)
        label.font = Typography.system(size: TypeScale.detail)
        delta.font = Typography.system(size: TypeScale.detail, weight: TypeScale.emphasis)
        for text in [value, label, delta] {
            text.maximumNumberOfLines = 1
            text.lineBreakMode = .byTruncatingTail
        }
        [value, label, delta].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    /// The extension design system's numeral role (cmux-tui design_system.rs `CMUX_ROLES`), the
    /// size webviews' `.cmux-app-scene-stat-value` draws; app scenes, not chrome, so not on TypeScale.
    static let numeralSize: CGFloat = 34

    /// The mark before a delta, the same text webviews draws (`TREND_MARK`).
    static func trendMark(_ trend: String?) -> String? {
        switch trend {
        case "up": "\u{2191}"
        case "down": "\u{2193}"
        default: nil
        }
    }

    /// The delta's tone: success when the trend is the good one, danger when not, secondary otherwise.
    static func deltaTone(trend: String?, goodTrend: String?) -> String {
        guard trend == "up" || trend == "down" else { return "secondary" }
        return trend == (goodTrend == "down" ? "down" : "up") ? "success" : "danger"
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        value.stringValue = node.string("value") ?? ""
        label.stringValue = node.string("label") ?? ""
        label.isHidden = label.stringValue.isEmpty
        let text = node.string("delta") ?? ""
        delta.stringValue = text.isEmpty ? "" : Self.trendMark(node.string("trend")).map { "\($0)\u{2009}\(text)" } ?? text
        delta.isHidden = text.isEmpty
        setAccessibilityLabel([value.stringValue, label.stringValue, delta.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override func paint() {
        performWithTheme {
            value.textColor = switch node.componentVariant {
            case .prominent: Palette.accentFill
            case .subtle: Palette.textSecondary
            case .standard: Palette.textPrimary
            }
            label.textColor = Palette.textSecondary
            let tone = Self.deltaTone(trend: node.string("trend"), goodTrend: node.string("goodTrend"))
            delta.textColor = AppJSON.string(tone).sceneColor ?? Palette.textSecondary
        }
    }

    private var hasCaption: Bool { !label.isHidden || !delta.isHidden }

    private var captionHeight: CGFloat {
        [label, delta].filter { !$0.isHidden }.map { ceil($0.naturalSize.height) }.max() ?? 0
    }

    override var contentNaturalWidth: CGFloat? {
        let parts = [label, delta].filter { !$0.isHidden }.map { ceil($0.naturalSize.width) }
        let caption = parts.reduce(0, +) + Self.captionGap * CGFloat(max(0, parts.count - 1))
        return max(ceil(value.naturalSize.width), caption)
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        ceil(value.naturalSize.height) + (hasCaption ? Self.lineGap + captionHeight : 0)
    }

    override func layoutContent(in rect: CGRect) {
        let valueHeight = ceil(value.naturalSize.height)
        value.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: valueHeight).integral
        var x = rect.minX
        let y = rect.minY + valueHeight + Self.lineGap
        for text in [label, delta] where !text.isHidden {
            let width = min(ceil(text.naturalSize.width), max(0, rect.maxX - x))
            text.frame = CGRect(x: x, y: y, width: width, height: captionHeight).integral
            x += width + Self.captionGap
        }
    }
}
