import AppKit
import CmuxNextDesign

/// One line in the view or search list: its node name, level and text. A borderless button
/// holding a value snapshot and an action only (no store below the list boundary).
final class ChiefMemoryLineRow: NSButton {
    private let open: @MainActor () -> Void

    init(name: String, detail: String, text: String, stale: Bool, selected: Bool, open: @escaping @MainActor () -> Void) {
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? Palette.selectionFill.cgColor : NSColor.clear.cgColor
        setAccessibilityIdentifier("chief-memory.line")
        setAccessibilityLabel("\(name), \(detail), \(text)")

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .monospacedSystemFont(ofSize: TypeScale.caption, weight: TypeScale.regular)
        nameLabel.textColor = .secondaryLabelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = Typography.caption
        detailLabel.textColor = .tertiaryLabelColor
        var top: [NSView] = [nameLabel, detailLabel]
        if stale {
            let badge = NSTextField(labelWithString: ChiefMemoryStrings.stale)
            badge.font = Typography.system(size: TypeScale.caption, weight: TypeScale.emphasis)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 6
            badge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.2).cgColor
            top.append(badge)
        }
        let header = NSStackView(views: top)
        header.orientation = .horizontal
        header.spacing = 6
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = Typography.body
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byTruncatingTail
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSStackView(views: [header, body])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { open() }
}
