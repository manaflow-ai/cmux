import AppKit
import CmuxNextDesign

/// One file explorer row: a disclosure arrow for folders, the item's icon and
/// name, indented by its depth.
final class FileExplorerCell: NSTableCellView {
    private let arrow = NSImageView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingMiddle
        for view in [arrow, icon, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        arrow.contentTintColor = .secondaryLabelColor
        let indent = arrow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space2)
        self.indent = indent
        NSLayoutConstraint.activate([
            indent,
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 10),
            icon.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: Metrics.space1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.space1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = name
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ row: FileExplorerRow) {
        indent?.constant = Metrics.space2 + CGFloat(row.depth) * 14
        arrow.image = row.isFolder ? NSImage(systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
                                             accessibilityDescription: nil) : nil
        icon.image = NSImage(systemSymbolName: row.isFolder ? "folder" : "doc", accessibilityDescription: nil)
        name.stringValue = row.name
        setAccessibilityLabel(row.name)
    }
}
