public import AppKit

/// The group hover card body (a sidebar workspace group header or a tab strip group chip): the
/// group's name and one shared hover card row per section of its `GroupHoverCardSummary`. One
/// instance is reused for every group card of its source; the app's one `HoverCardPanel` hosts it.
@MainActor
public final class GroupHoverCardView: NSView {
    private static var padding: CGFloat { Metrics.space4 }
    static var cardWidth: CGFloat { 280 }
    static var minCardWidth: CGFloat { 180 }

    private let titleLabel = ChromeLabel(labelWithString: "")
    private let stack = NSStackView()
    private var rows: [HoverCardRowView] = []
    public private(set) var summary = GroupHoverCardSummary(title: "", blocks: [])

    public init() {
        super.init(frame: .zero)
        titleLabel.font = Typography.bodyEmphasized
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3
        titleLabel.preferredMaxLayoutWidth = Self.cardWidth - 2 * Self.padding
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        addSubview(stack)
        let p = Self.padding
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.cardWidth),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minCardWidth),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `summary`.
    public func configure(_ summary: GroupHoverCardSummary) {
        self.summary = summary
        titleLabel.stringValue = summary.title
        while rows.count < summary.blocks.count {
            let row = HoverCardRowView()
            row.textLabel.setContentCompressionResistancePriority(.keepsTextWidth, for: .horizontal)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true
            rows.append(row)
        }
        let wrap = Self.cardWidth - 2 * Self.padding
        for (index, row) in rows.enumerated() {
            guard index < summary.blocks.count else {
                row.isHidden = true
                continue
            }
            let block = summary.blocks[index]
            row.isHidden = false
            let ink: HoverCardTone = switch block.section == .status ? block.tone : .secondary {
            case .secondary: .secondary
            case .working: .working
            case .attention: .attention
            case .danger: .danger
            }
            row.configure(HoverCardRowContent(text: block.lines.joined(separator: "\n"), ink: ink, lines: block.lines.count),
                          image: nil, wrapWidth: wrap)
        }
        setAccessibilityLabel(summary.lines.joined(separator: ", "))
        applyColors()
    }

    /// The text the card shows, one entry per line (tests, `debug.hover_cards`).
    public var lines: [String] {
        [titleLabel.stringValue] + rows.filter { !$0.isHidden }.flatMap { $0.textLabel.stringValue.components(separatedBy: "\n") }
    }

    /// Recolors in the card's theme scope; the panel runs it on adopt and on every scope change.
    public func applyColors() {
        performWithTheme { titleLabel.textColor = Palette.textPrimary }
        for row in rows { row.applyColors() }
    }
}

extension GroupHoverCardView: HoverCardTextReporting {
    public var reportedLines: [String] { lines }
}
