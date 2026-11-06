import AppKit
import CmuxNextDesign

/// One list row: name, schedule and target, the next time, the last result's dot. A value snapshot
/// and a closure (the list snapshot rule); a click selects it.
final class AutomationListRow: NSView {
    /// The row it shows.
    let row: AutomationRow
    /// Whether it is the selected row.
    let selected: Bool
    private let select: @MainActor () -> Void

    init(row: AutomationRow, selected: Bool, palette: AutomationsPalette, strings: AutomationStrings, now: Date,
         select: @escaping @MainActor () -> Void) {
        self.row = row
        self.selected = selected
        self.select = select
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = selected ? palette.selection.cgColor : NSColor.clear.cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (row.enabled ? palette.color(row.last) : palette.tertiary).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        // The dot sits on the name's first line, 5 pt down, as it did beside the SwiftUI text.
        let dotColumn = NSView()
        dotColumn.translatesAutoresizingMaskIntoConstraints = false
        dotColumn.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: dotColumn.leadingAnchor), dot.trailingAnchor.constraint(equalTo: dotColumn.trailingAnchor),
            dot.topAnchor.constraint(equalTo: dotColumn.topAnchor, constant: 5), dot.bottomAnchor.constraint(equalTo: dotColumn.bottomAnchor),
        ])

        let name = Self.label(row.name, font: palette.emphasized, color: palette.text)
        let detail = Self.label("\(row.schedule) · \(strings.target(row.target))", font: palette.caption, color: palette.secondary)
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.init(1), for: .horizontal)

        let chip = AutomationChip(text: Self.badge(row, strings: strings, now: now), palette: palette)
        let line = NSStackView(views: [dotColumn, texts, chip])
        line.orientation = .horizontal
        line.alignment = .top
        line.distribution = .fill
        line.spacing = 10
        line.setCustomSpacing(4, after: texts)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.name)
        setAccessibilitySelected(selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Paused, failed, or the next time.
    static func badge(_ row: AutomationRow, strings: AutomationStrings, now: Date) -> String {
        if !row.enabled { return strings.paused }
        if row.needsYou { return strings.failed }
        return row.nextRun.map { AutomationsPageView.time($0, now: now) } ?? "–"
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        select()
    }

    override func accessibilityPerformPress() -> Bool {
        select()
        return true
    }
}
