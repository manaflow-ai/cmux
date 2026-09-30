public import AppKit
import CmuxNextDesign

/// The resource lines of a hover card, in theme colors.
///
/// - Tab: one line, "CPU 2.3% · Memory 145.2 MB" (dashes until the first
///   sample, the CPU dash until the second).
/// - Workspace: the total line, the heaviest tabs (title and compact
///   numbers), and the shared processes on their own line.
public final class ResourceSummaryView: NSView {
    public enum Style: Equatable {
        case tab
        case workspace(topConsumers: Int)
    }

    public var style: Style = .tab {
        didSet { if style != oldValue { render() } }
    }

    private let stack = NSStackView()
    private let totalLabel = ResourceSummaryView.label(Typography.caption)
    private let sharedLabel = ResourceSummaryView.label(Typography.caption)
    private var rows: [(title: NSTextField, value: NSTextField, row: NSStackView)] = []
    private var report: ResourceReport?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        stack.addArrangedSubview(totalLabel)
        stack.addArrangedSubview(sharedLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `report`; nil shows the placeholder line.
    public func show(_ report: ResourceReport?) {
        self.report = report
        render()
    }

    /// The text the view shows, one entry per line (tests, accessibility).
    public var lines: [String] {
        stack.arrangedSubviews.filter { !$0.isHidden }.compactMap { view in
            if let field = view as? NSTextField { return field.stringValue }
            if let row = view as? NSStackView {
                return row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
            }
            return nil
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme colors for every label, again on each theme change.
    private func applyColors() {
        performWithTheme {
            totalLabel.textColor = Palette.textSecondary
            sharedLabel.textColor = Palette.textTertiary
            for row in rows {
                row.title.textColor = Palette.textPrimary
                row.value.textColor = Palette.textSecondary
            }
        }
    }

    private func render() {
        totalLabel.font = Typography.caption
        sharedLabel.font = Typography.caption
        switch style {
        case .tab:
            if let tab = report?.tabs.first {
                totalLabel.stringValue = tab.available ? ResourceFormat.line(tab.usage) : Strings.unavailable
            } else {
                totalLabel.stringValue = Strings.cpuMemory(cpu: Strings.pending, memory: Strings.pending)
            }
            setRowCount(0)
            sharedLabel.isHidden = true
        case .workspace(let limit):
            if let report {
                totalLabel.stringValue = ResourceFormat.line(report.total)
            } else {
                totalLabel.stringValue = Strings.cpuMemory(cpu: Strings.pending, memory: Strings.pending)
            }
            let top = report?.topConsumers(limit) ?? []
            setRowCount(top.count)
            for (row, tab) in zip(rows, top) {
                row.title.stringValue = tab.title.isEmpty ? Strings.untitled : tab.title
                row.title.font = Typography.caption
                row.value.font = Typography.caption
                row.value.stringValue = tab.available ? ResourceFormat.compact(tab.usage) : Strings.pending
            }
            if let report, !report.sharedRoles.isEmpty {
                sharedLabel.stringValue = ResourceFormat.shared(report.shared, roles: report.sharedRoles)
                sharedLabel.isHidden = false
            } else {
                sharedLabel.isHidden = true
            }
        }
        setAccessibilityLabel(lines.joined(separator: "\n"))
    }

    private func setRowCount(_ count: Int) {
        while rows.count < count {
            let title = Self.label(Typography.caption)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let value = Self.label(Typography.caption)
            value.alignment = .right
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            value.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [title, value])
            row.orientation = .horizontal
            row.spacing = Metrics.space2
            row.distribution = .fill
            stack.insertArrangedSubview(row, at: stack.arrangedSubviews.count - 1)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append((title, value, row))
            applyColors()
        }
        for (index, row) in rows.enumerated() { row.row.isHidden = index >= count }
    }

    private static func label(_ font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}
