import AppKit

/// A single row in the Notes outline view.
///
/// Session folders adopt the Vault look — the agent's brand icon plus a
/// relative timestamp — while notes and folders use Files-explorer icons, so the
/// tab reads as a combination of the Files tree and the Vault. Resume is offered
/// via double-click and the context menu rather than a per-row button, matching
/// the Vault's clean rows.
final class NotesTreeCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("NotesTreeCellView")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")

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
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeField.translatesAutoresizingMaskIntoConstraints = false
        timeField.alignment = .right
        timeField.lineBreakMode = .byClipping
        timeField.isEditable = false
        timeField.isBordered = false
        timeField.drawsBackground = false
        timeField.textColor = .tertiaryLabelColor
        timeField.font = .systemFont(ofSize: 10)
        timeField.setContentHuggingPriority(.required, for: .horizontal)
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(timeField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            timeField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            timeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Configure for a node, matching Files-explorer density/typography.
    func configure(with node: NotesTreeNode, style: FileExplorerStyle) {
        titleField.stringValue = node.displayName
        titleField.font = style.nameFont
        titleField.textColor = .labelColor

        switch node.kind {
        case .note:
            applySymbolIcon("doc.text", tint: style.fileIconTint)
            setTime(nil)
        case .folder:
            applySymbolIcon("folder", tint: style.folderIconTint)
            setTime(nil)
        case .sessionFolder(let marker):
            applyAgentIcon(forAgent: marker.agent)
            setTime(marker.modified)
        }
    }

    private func setTime(_ modified: TimeInterval?) {
        if let modified {
            timeField.stringValue = NotesTreeCellView.relativeTimeString(modified)
            timeField.isHidden = false
        } else {
            timeField.stringValue = ""
            timeField.isHidden = true
        }
    }

    private func applySymbolIcon(_ name: String, tint: NSColor) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = tint
    }

    /// Use the agent's full-color brand asset (Claude sunburst, etc.), matching
    /// the Vault; fall back to a conversation glyph for unknown agents.
    private func applyAgentIcon(forAgent agent: String) {
        if let sessionAgent = SessionAgent(rawValue: agent),
           let assetName = sessionAgent.assetName,
           let image = NSImage(named: assetName) {
            image.isTemplate = false
            iconView.image = image
            iconView.contentTintColor = nil
            return
        }
        let fallback = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        fallback?.isTemplate = true
        iconView.image = fallback
        iconView.contentTintColor = .controlAccentColor
    }

    private static func relativeTimeString(_ modified: TimeInterval) -> String {
        SessionIndexView.relativeFormatter.localizedString(
            for: Date(timeIntervalSince1970: modified),
            relativeTo: Date()
        )
    }
}
