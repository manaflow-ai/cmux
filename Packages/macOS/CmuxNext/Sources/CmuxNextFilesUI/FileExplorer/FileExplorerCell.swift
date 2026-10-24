package import AppKit
package import CmuxNextDesign

/// One file explorer row: a disclosure arrow for folders, the item's icon and
/// name, indented by its depth, and its git state's letter at the end. The
/// name becomes editable for Rename.
package final class FileExplorerCell: NSTableCellView {
    private let arrow = NSImageView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint?

    package init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingMiddle
        // Rename makes the name editable; its caret shows focus, not a ring.
        name.focusRingType = .none
        badge.font = Typography.caption
        badge.alignment = .right
        for view in [arrow, icon, name, badge] as [NSView] {
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
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -Metrics.space1),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
        ])
        textField = name
        imageView = icon
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    package func show(_ row: FileExplorerRow) {
        indent?.constant = Metrics.space2 + CGFloat(row.depth) * 14
        arrow.image = row.isFolder ? NSImage(systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
                                             accessibilityDescription: nil) : nil
        icon.image = NSImage(systemSymbolName: row.isFolder ? "folder" : "doc", accessibilityDescription: nil)
        name.stringValue = row.name
        endEditing()
        badge.stringValue = row.git?.badge ?? ""
        badge.textColor = row.git.map(Self.color) ?? .secondaryLabelColor
        setAccessibilityLabel(row.git.map { "\(row.name), \(FileExplorerStrings.gitState($0))" } ?? row.name)
    }

    /// Makes the name editable (Rename); `delegate` gets the end of editing.
    package func beginEditing(delegate: any NSTextFieldDelegate) {
        name.isEditable = true
        name.isSelectable = true // text-focus-allow: the rename field in a sidebar row; the ring shows where typing goes (accessibility).
        name.delegate = delegate
        window?.makeFirstResponder(name)
        name.currentEditor()?.selectedRange = NSRange(location: 0, length: ((name.stringValue as NSString).deletingPathExtension as NSString).length)
    }

    /// The name is a label again.
    package func endEditing() {
        name.isEditable = false
        name.isSelectable = false
        name.delegate = nil
    }

    private static func color(_ state: FileGitState) -> NSColor {
        switch state {
        case .modified, .renamed, .containsChanges: .systemOrange
        case .added, .untracked: .systemGreen
        case .deleted, .conflicted: .systemRed
        }
    }
}
