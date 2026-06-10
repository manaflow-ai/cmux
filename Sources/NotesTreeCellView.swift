import AppKit

/// A single row in the Notes outline view.
///
/// Notes and folders use the Files-explorer icon treatment (same symbols,
/// sizes, and tints from ``FileExplorerStyle``) so the tab reads exactly like
/// the Files tree; session folders adopt the Vault look — the agent's brand
/// icon plus a relative timestamp. Resume is offered via the context menu and
/// drag-to-pane rather than a per-row button, matching the Vault's clean rows.
final class NotesTreeCellView: NSTableCellView, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("NotesTreeCellView")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    /// Pending inline-rename commit; non-nil only while the title is editable.
    /// The Bool is true when the commit came from the Return key (vs. a
    /// click-away), so callers can gate follow-up actions like auto-opening.
    private var renameCommit: ((String, Bool) -> Void)?
    /// Always runs when editing tears down (commit, Escape, or cell reuse) —
    /// before any commit — so the owner can lift its rename-in-progress state.
    private var renameEnded: (() -> Void)?

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

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            timeField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            timeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Configure for a node, matching Files-explorer density/typography.
    func configure(with node: NotesTreeNode, style: FileExplorerStyle) {
        endRename(cancelled: true)
        titleField.stringValue = node.displayName
        titleField.font = style.nameFont
        titleField.textColor = .labelColor
        titleField.toolTip = node.path
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        switch node.kind {
        case .note:
            applySymbolIcon("doc.text", style: style, tint: style.fileIconTint)
            setTime(nil)
        case .folder:
            applySymbolIcon("folder.fill", style: style, tint: style.folderIconTint)
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

    private func applySymbolIcon(_ name: String, style: FileExplorerStyle, tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: style.iconSize, weight: style.iconWeight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
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

    // MARK: - Inline rename

    /// Make the title editable in place (VSCode-style rename). `onCommit` runs
    /// once with the typed name on Enter or focus loss; Escape cancels.
    /// `onEnded` runs whenever editing tears down, before any commit.
    func beginRename(
        initialText: String,
        onCommit: @escaping (String, Bool) -> Void,
        onEnded: @escaping () -> Void
    ) {
        renameCommit = onCommit
        renameEnded = onEnded
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.stringValue = initialText
        titleField.delegate = self
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    /// Tear down editing state. When `cancelled`, the pending commit is dropped
    /// (used by Escape and by cell reuse).
    private func endRename(cancelled: Bool) {
        if cancelled { renameCommit = nil }
        guard titleField.isEditable else { return }
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.delegate = nil
        if cancelled { titleField.abortEditing() }
        let ended = renameEnded
        renameEnded = nil
        ended?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let typed = titleField.stringValue
        let commit = renameCommit
        renameCommit = nil
        // Enter hands focus back to the tree; a click-away keeps focus where
        // the user clicked.
        let movementRaw = (obj.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        let viaReturn = movementRaw == NSTextMovement.return.rawValue
        endRename(cancelled: false)
        if viaReturn {
            window?.makeFirstResponder(enclosingOutlineView)
        }
        // Run last: the commit reloads the outline and reconfigures this cell.
        commit?(typed, viaReturn)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename(cancelled: true)
        window?.makeFirstResponder(enclosingOutlineView)
        return true
    }

    private var enclosingOutlineView: NSOutlineView? {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView { return outlineView }
            view = candidate.superview
        }
        return nil
    }
}

/// Notes row: the Files-explorer selection treatment plus a subtle hover
/// highlight (VSCode-style), styled by ``FileExplorerStyle``. Nested rows
/// draw indent guides (one thin vertical line per ancestor level) so it
/// stays readable which session/folder a row is filed under.
final class NotesTreeRowView: FileExplorerRowView {
    /// Outline depth of this row (0 = top level). Drives the indent guides.
    var indentLevel = 0 {
        didSet { if oldValue != indentLevel { needsDisplay = true } }
    }
    var indentationWidth: CGFloat = 16

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        super.mouseExited(with: event)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        indentLevel = 0
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        drawIndentGuides()
        guard isHovered, !isSelected else { return }
        let style = FileExplorerStyle.current
        let inset = style.selectionInset
        let rect = bounds.insetBy(dx: inset, dy: inset > 0 ? 1 : 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: style.selectionRadius, yRadius: style.selectionRadius)
        style.hoverColor.setFill()
        path.fill()
    }

    /// One vertical hairline per ancestor level, aligned under that
    /// ancestor's disclosure chevron, spanning the full row height so the
    /// lines connect across rows into continuous guides.
    private func drawIndentGuides() {
        guard indentLevel > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        for depth in 1...indentLevel {
            let x = CGFloat(depth) * indentationWidth - 6
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}
