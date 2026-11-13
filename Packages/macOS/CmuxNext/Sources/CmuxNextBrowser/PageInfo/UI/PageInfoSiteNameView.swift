import AppKit
import CmuxNextDesign

/// A site's name in the bubble's header. A name wider than the header is cut in its middle
/// (``PageInfoSite/fittedName(_:width:measure:)``): its end, the registrable domain and port,
/// always shows. The whole name is the tooltip.
final class PageInfoSiteNameView: NSView {
    private let name: String
    private let label: ThemedLabel
    /// The width the whole name draws at.
    private let fullWidth: CGFloat
    private var fittedWidth: CGFloat = -1

    init(name: String, font: NSFont, color: @escaping @autoclosure () -> NSColor) {
        self.name = name
        let label = PageInfoStyle.label(name, font: font, color: color())
        self.label = label
        fullWidth = ceil(label.intrinsicContentSize.width)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // A name still too wide after the cut loses its start, never its end.
        label.lineBreakMode = .byTruncatingHead
        label.setAccessibilityValue(name)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: fullWidth),
            widthAnchor.constraint(equalToConstant: fullWidth).prioritized(.defaultHigh),
        ])
        themedToolTip = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text the label shows (tests).
    var shownName: String { label.stringValue }

    override func layout() {
        if bounds.width != fittedWidth {
            fittedWidth = bounds.width
            let shown = bounds.width >= fullWidth ? name : fitted(to: bounds.width)
            if label.stringValue != shown { label.stringValue = shown }
        }
        super.layout()
    }

    private func fitted(to width: CGFloat) -> String {
        guard let font = label.font else { return name }
        // A label draws its text 2 pt inside each edge.
        return PageInfoSite.fittedName(name, width: width) { text in
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
        }
    }
}
