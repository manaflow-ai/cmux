import AppKit

/// A single row in the Notes outline view.
///
/// Renders a note, a plain folder, or a session folder. Session folders show a
/// conversation icon and a trailing Resume button wired to an injected closure
/// (the cell holds no store or model reference — only value snapshots and a
/// callback).
final class NotesTreeCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("NotesTreeCellView")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let resumeButton = NSButton()

    private var onResume: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false

        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.bezelStyle = .inline
        resumeButton.isBordered = false
        resumeButton.imagePosition = .imageOnly
        resumeButton.image = NSImage(
            systemSymbolName: "play.circle",
            accessibilityDescription: String(localized: "notes.session.resume", defaultValue: "Resume session")
        )
        resumeButton.contentTintColor = .controlAccentColor
        resumeButton.target = self
        resumeButton.action = #selector(resumeTapped)
        resumeButton.toolTip = String(localized: "notes.session.resume", defaultValue: "Resume session")
        resumeButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(resumeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            resumeButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            resumeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            resumeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            resumeButton.widthAnchor.constraint(equalToConstant: 16),
            resumeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    /// Configure for a node. `onResume` is invoked when the session Resume button
    /// is tapped (only shown for session folders).
    func configure(with node: NotesTreeNode, style: FileExplorerStyle, onResume: (() -> Void)?) {
        let symbol: String
        let tint: NSColor
        switch node.kind {
        case .note:
            symbol = "doc.text"
            tint = style.fileIconTint
        case .folder:
            symbol = "folder"
            tint = style.folderIconTint
        case .sessionFolder:
            symbol = "bubble.left.and.bubble.right"
            tint = .controlAccentColor
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint
        titleField.stringValue = node.displayName
        titleField.font = style.nameFont
        titleField.textColor = .labelColor

        let isSession = node.kind.isDirectory && {
            if case .sessionFolder = node.kind { return true } else { return false }
        }()
        resumeButton.isHidden = !isSession
        self.onResume = onResume
    }

    @objc private func resumeTapped() {
        onResume?()
    }
}
