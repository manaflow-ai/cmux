import AppKit
import CmuxSidebar
import Foundation

/// The custom metadata block under a workspace row: keyed status entries
/// (collapsed past 3 behind Show more/less) and keyed markdown blocks
/// (collapsed past 1). AppKit port of `SidebarMetadataRows` /
/// `SidebarMetadataMarkdownBlocks`. Expansion state lives in
/// `SidebarWorkspaceCellTransientState` so the sizing cell measures the same
/// layout the visible cell shows.
final class SidebarWorkspaceCellMetadataSection: NSView {
    private static let collapsedEntryLimit = 3
    private static let collapsedBlockLimit = 1
    private static let maxBlockLines = 12
    private static let maxBlockCharacters = 4096

    private let column = SidebarWorkspaceCellStackFactory.vertical(spacing: 4, alignment: .width)
    private let entriesColumn = SidebarWorkspaceCellStackFactory.vertical(spacing: 2, alignment: .width)
    private let entriesPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellMetadataEntryRowView>()
    private let entriesToggle = SidebarWorkspaceCellButton()
    private let blocksColumn = SidebarWorkspaceCellStackFactory.vertical(spacing: 3, alignment: .width)
    private let blocksPool = SidebarWorkspaceCellRowPool<SidebarWorkspaceCellLabel>()
    private let blocksToggle = SidebarWorkspaceCellButton()

    private var workspaceId: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        entriesToggle.imagePosition = .noImage
        entriesToggle.alignment = .left
        entriesToggle.onPress = { [weak self] in self?.toggleEntries() }
        blocksToggle.imagePosition = .noImage
        blocksToggle.alignment = .left
        blocksToggle.onPress = { [weak self] in self?.toggleBlocks() }
        column.addArrangedSubview(entriesColumn)
        column.addArrangedSubview(blocksColumn)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private var onFocus: (() -> Void)?

    func update(_ context: SidebarWorkspaceCellContext) {
        let entries = context.workspace.metadataEntries
        let blocks = context.workspace.metadataBlocks
        guard context.settings.visibleAuxiliaryDetails.showsMetadata,
              !entries.isEmpty || !blocks.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        workspaceId = context.snapshot.workspaceId
        let actions = context.actions
        onFocus = actions.map { resolved in { resolved.select(NSEvent.modifierFlags) } }
        let state = SidebarWorkspaceCellTransientState.shared.state(for: context.snapshot.workspaceId)
        updateEntries(entries, context: context, isExpanded: state.metadataEntriesExpanded)
        updateBlocks(blocks, context: context, isExpanded: state.metadataBlocksExpanded)
    }

    private func updateEntries(
        _ entries: [SidebarStatusEntry],
        context: SidebarWorkspaceCellContext,
        isExpanded: Bool
    ) {
        entriesColumn.isHidden = entries.isEmpty
        guard !entries.isEmpty else { return }
        let style = context.style
        let visible = (!isExpanded && entries.count > Self.collapsedEntryLimit)
            ? Array(entries.prefix(Self.collapsedEntryLimit))
            : entries
        let rows = entriesPool.prepare(count: visible.count, in: entriesColumn) {
            SidebarWorkspaceCellMetadataEntryRowView()
        }
        for (entry, row) in zip(visible, rows) {
            row.update(entry: entry, style: style, onFocus: onFocus)
        }

        // The toggle stays last in the column.
        if entriesToggle.superview !== entriesColumn {
            entriesColumn.addArrangedSubview(entriesToggle)
        } else {
            entriesColumn.removeArrangedSubview(entriesToggle)
            entriesColumn.addArrangedSubview(entriesToggle)
        }
        let showsToggle = entries.count > Self.collapsedEntryLimit
        entriesToggle.isHidden = !showsToggle
        if showsToggle {
            let title = isExpanded
                ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less")
                : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")
            entriesToggle.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: SidebarWorkspaceCellFonts.system(style.fontSize(10), weight: .semibold),
                    .foregroundColor: style.isActive
                        ? style.secondary(0.65)
                        : SidebarWorkspaceCellStyle.dimmed(.secondaryLabelColor, 0.9),
                ]
            )
        }
        entriesColumn.toolTip = entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }.joined(separator: "\n")
    }

    private func updateBlocks(
        _ blocks: [SidebarMetadataBlock],
        context: SidebarWorkspaceCellContext,
        isExpanded: Bool
    ) {
        blocksColumn.isHidden = blocks.isEmpty
        guard !blocks.isEmpty else { return }
        let style = context.style
        let visible = (!isExpanded && blocks.count > Self.collapsedBlockLimit)
            ? Array(blocks.prefix(Self.collapsedBlockLimit))
            : blocks
        let font = SidebarWorkspaceCellFonts.system(style.fontSize(10))
        let color = style.isActive ? style.secondary(0.8) : NSColor.secondaryLabelColor
        let rows = blocksPool.prepare(count: visible.count, in: blocksColumn) {
            let label = SidebarWorkspaceCellLabel()
            label.wrapsText = true
            label.maximumNumberOfLines = Self.maxBlockLines
            return label
        }
        for (block, label) in zip(visible, rows) {
            let display = block.markdown.sidebarCellBoundedDisplayString(
                maxDisplayedLines: Self.maxBlockLines,
                maxDisplayedCharacters: Self.maxBlockCharacters
            )
            if let rendered = SidebarMetadataMarkdownRenderer.rendered(display) {
                label.attributedStringValue = SidebarWorkspaceCellMarkdown.nsAttributed(
                    from: rendered,
                    baseFont: font,
                    color: color
                )
            } else {
                label.font = font
                label.textColor = color
                label.stringValue = display
            }
        }

        if blocksToggle.superview !== blocksColumn {
            blocksColumn.addArrangedSubview(blocksToggle)
        } else {
            blocksColumn.removeArrangedSubview(blocksToggle)
            blocksColumn.addArrangedSubview(blocksToggle)
        }
        let showsToggle = blocks.count > Self.collapsedBlockLimit
        blocksToggle.isHidden = !showsToggle
        if showsToggle {
            let title = isExpanded
                ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details")
                : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")
            blocksToggle.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: SidebarWorkspaceCellFonts.system(style.fontSize(10), weight: .semibold),
                    .foregroundColor: style.isActive
                        ? style.secondary(0.65)
                        : SidebarWorkspaceCellStyle.dimmed(.secondaryLabelColor, 0.9),
                ]
            )
        }
    }

    private func toggleEntries() {
        guard let workspaceId else { return }
        onFocus?()
        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
            $0.metadataEntriesExpanded.toggle()
        }
    }

    private func toggleBlocks() {
        guard let workspaceId else { return }
        onFocus?()
        SidebarWorkspaceCellTransientState.shared.update(workspaceId) {
            $0.metadataBlocksExpanded.toggle()
        }
    }
}

/// One keyed metadata entry line: optional icon (SF symbol, `emoji:`, or
/// `text:` prefix), the value text (inline markdown when requested,
/// underlined when it opens a URL).
final class SidebarWorkspaceCellMetadataEntryRowView: NSView {
    private let row = SidebarWorkspaceCellStackFactory.horizontal(spacing: 4)
    private let symbolIcon = SidebarWorkspaceCellIconView()
    private let textIconLabel = SidebarWorkspaceCellLabel()
    private let valueLabel = SidebarWorkspaceCellLabel()
    private let spacer = NSView()
    private let clickButton = SidebarWorkspaceCellButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        textIconLabel.setContentHuggingPriority(.required, for: .horizontal)
        textIconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        row.addArrangedSubview(symbolIcon)
        row.addArrangedSubview(textIconLabel)
        row.addArrangedSubview(valueLabel)
        row.addArrangedSubview(spacer)
        addSubview(row)
        clickButton.imagePosition = .noImage
        clickButton.title = ""
        addSubview(clickButton)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(entry: SidebarStatusEntry, style: SidebarWorkspaceCellStyle, onFocus: (() -> Void)?) {
        let foreground = foregroundColor(entry: entry, style: style)
        updateIcon(entry: entry, style: style, color: SidebarWorkspaceCellStyle.dimmed(foreground, 0.95))

        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        let font = SidebarWorkspaceCellFonts.system(style.fontSize(10))
        let underlined = entry.url != nil
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
        ]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if entry.format == .markdown,
           let attributed = try? AttributedString(
               markdown: display,
               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            let rendered = SidebarWorkspaceCellMarkdown.nsAttributed(
                from: attributed,
                baseFont: font,
                color: foreground
            ).mutableCopy() as? NSMutableAttributedString
            if underlined, let rendered {
                rendered.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 0, length: rendered.length)
                )
            }
            valueLabel.attributedStringValue = rendered
                ?? NSAttributedString(string: display, attributes: attributes)
        } else {
            valueLabel.attributedStringValue = NSAttributedString(string: display, attributes: attributes)
        }

        if let url = entry.url {
            clickButton.isHidden = false
            clickButton.isInteractionEnabled = true
            clickButton.toolTip = url.absoluteString
            clickButton.onPress = {
                onFocus?()
                NSWorkspace.shared.open(url)
            }
        } else {
            // Tapping a plain entry only focuses the workspace, which the
            // table's own row click already performs; no overlay needed.
            clickButton.isHidden = true
            clickButton.isInteractionEnabled = false
        }
    }

    private func updateIcon(entry: SidebarStatusEntry, style: SidebarWorkspaceCellStyle, color: NSColor) {
        symbolIcon.isHidden = true
        textIconLabel.isHidden = true
        guard let raw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        if raw.hasPrefix("emoji:") {
            let value = String(raw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return }
            textIconLabel.isHidden = false
            textIconLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(9))
            textIconLabel.textColor = color
            textIconLabel.stringValue = value
            return
        }
        if raw.hasPrefix("text:") {
            let value = String(raw.dropFirst("text:".count))
            guard !value.isEmpty else { return }
            textIconLabel.isHidden = false
            textIconLabel.font = SidebarWorkspaceCellFonts.system(style.fontSize(8), weight: .semibold)
            textIconLabel.textColor = color
            textIconLabel.stringValue = value
            return
        }
        let symbolName = raw.hasPrefix("sf:") ? String(raw.dropFirst("sf:".count)) : raw
        guard !symbolName.isEmpty,
              SidebarWorkspaceCellSymbols.image(symbolName, pointSize: 8) != nil else {
            return
        }
        symbolIcon.isHidden = false
        symbolIcon.setSymbol(symbolName, pointSize: style.fontSize(8), weight: .medium, color: color)
    }

    private func foregroundColor(entry: SidebarStatusEntry, style: SidebarWorkspaceCellStyle) -> NSColor {
        let explicit = entry.color.flatMap { NSColor(hex: $0) }
        if style.isActive, explicit != nil {
            return style.secondary(0.95)
        }
        if let explicit {
            return explicit
        }
        return style.isActive
            ? SidebarWorkspaceCellStyle.dimmed(style.secondary(0.95), 0.84)
            : .secondaryLabelColor
    }
}
