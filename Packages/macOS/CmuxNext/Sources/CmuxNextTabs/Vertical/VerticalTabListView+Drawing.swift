public import AppKit
import CmuxNextDesign
import CmuxNextIcons

// Drawing the rows: one pass over the layout, every color resolved in the list's theme scope, so a
// theme change only needs a redraw. No animation: a change shows in the next frame.
extension VerticalTabListView {
    typealias Row = VerticalTabListLayout.Row

    public override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            if isHoverExpanded {
                // Widened over the content: an opaque panel, as the strip's own background.
                Palette.windowBackground.setFill()
                bounds.fill()
                Palette.separator.setFill()
                CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
            }
            let visible = CGRect(x: 0, y: scrollOffset, width: bounds.width, height: bounds.height)
            for line in listLayout.groupLines where line.frame.intersects(visible) {
                guard let group = model.group(line.group) else { continue }
                group.tint.headerFill.setFill()
                NSBezierPath(roundedRect: viewRect(line.frame), xRadius: line.frame.width / 2, yRadius: line.frame.width / 2).fill()
            }
            for row in listLayout.rows where row.frame.insetBy(dx: 0, dy: -1).intersects(visible) {
                drawRow(row)
            }
            if let drag, drag.isActive, let slot = drag.slot {
                Palette.accent.setFill()
                let mark = viewRect(slot.indicator)
                NSBezierPath(roundedRect: mark, xRadius: min(mark.width, mark.height) / 2, yRadius: min(mark.width, mark.height) / 2).fill()
            }
        }
    }

    private func drawRow(_ row: Row) {
        switch row.kind {
        case .pinned(let id), .tab(let id):
            guard let item = model.tab(id) else { return }
            drawTab(item, row: row)
        case .groupHeader(let id):
            guard let group = model.group(id) else { return }
            drawGroupHeader(group, row: row)
        case .separator:
            Palette.separator.setFill()
            let frame = viewRect(row.frame)
            CGRect(x: frame.minX + metrics.padding / 2, y: frame.midY.rounded(.down), width: max(0, frame.width - metrics.padding), height: 1 / scale).fill()
        case .newTab:
            drawNewTab(row)
        }
    }

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Tabs

    /// Fill behind a tab: the selection, the lighter fill of the other selected tabs, or hover.
    private func fill(for item: TabItem, hovered: Bool) -> NSColor? {
        if item.id == model.selectedID { return Palette.selectionFill }
        if model.multiSelection.isMultiple, model.multiSelection.contains(item.id) { return Palette.secondarySelectionFill }
        return hovered && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : nil
    }

    private func drawTab(_ item: TabItem, row: Row) {
        let frame = viewRect(row.frame)
        let isHovered = hovered == row.kind
        let dragged = drag?.isActive == true && drag?.id == item.id
        let alpha: CGFloat = dragged ? 0.45 : 1
        if let fill = fill(for: item, hovered: isHovered) {
            fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
            NSBezierPath(roundedRect: frame, xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius).fill()
        }
        let selected = item.id == model.selectedID
        let text = selected ? Palette.textPrimary : Palette.textSecondary
        let tile: Bool = if case .pinned = row.kind { true } else { false }
        let iconOnly = tile || !showsTitles
        let size = metrics.iconSize
        let iconX = iconOnly ? frame.midX - size / 2 : frame.minX + metrics.padding
        let iconFrame = CGRect(x: pixel(iconX), y: pixel(frame.midY - size / 2), width: size, height: size)
        drawIcon(item, in: iconFrame, tint: item.tint?.markColor ?? text, alpha: alpha)
        if let badge = badgeColor(item) {
            // Unread or status: a dot on the icon's corner while titles are hidden, else at the row's end.
            let dot = metrics.iconSize * 0.4
            let place = iconOnly || isHovered || closeFrame(row) != nil
                ? CGRect(x: iconFrame.maxX - dot * 0.6, y: iconFrame.minY - dot * 0.4, width: dot, height: dot)
                : CGRect(x: frame.maxX - metrics.padding - dot, y: frame.midY - dot / 2, width: dot, height: dot)
            badge.setFill()
            NSBezierPath(ovalIn: place).fill()
        }
        guard !iconOnly else { return }
        var titleEnd = frame.maxX - metrics.padding
        if let close = closeFrame(row).map(viewRect) {
            drawClose(in: close, hovered: hoveredClose == item.id, pressed: press?.target == .close(item.id))
            titleEnd = close.minX - Metrics.space1
        }
        if let audio = audioFrame(row).map(viewRect), let sound = item.audio {
            let name: IconName = sound == .muted ? .browserTabMuted : .browserTabAudio
            let hot = hoveredAudio == item.id
            if hot, let fill = ChromeHover.fillColor(.init(hovering: true, pressed: press?.target == .audio(item.id))) {
                fill.setFill()
                NSBezierPath(roundedRect: audio, xRadius: audio.height / 2, yRadius: audio.height / 2).fill()
            }
            let glyph = TabCell.audioIconSize
            if let image = TabPackIconCache.shared.image(name: name, tint: hot ? Palette.textPrimary : Palette.textSecondary, size: glyph, scale: scale) {
                draw(image, in: CGRect(x: audio.midX - glyph / 2, y: audio.midY - glyph / 2, width: glyph, height: glyph), alpha: alpha)
            }
            titleEnd = audio.minX - Metrics.space1
        }
        let titleX = iconFrame.maxX + TabTunables.iconTitleSpacing.value
        let title = item.title.isEmpty ? Strings.untitled : item.title
        drawTitle(title, font: selected ? Typography.bodyEmphasized : Typography.body, color: text.withAlphaComponent(alpha),
                  in: CGRect(x: titleX, y: frame.minY, width: max(0, titleEnd - titleX), height: frame.height))
    }

    /// theme-scoped, as `TabCell.badgeColor`.
    private func badgeColor(_ item: TabItem) -> NSColor? {
        switch item.status {
        case .needsInput: Palette.attention
        case .success: Palette.success
        case .failure: Palette.danger
        case .none: item.isUnread ? Palette.notificationBlue : nil
        }
    }

    /// The tab's icon, as the strip's cell draws it (`TabCell.iconImage`): a pinned tab with no icon
    /// shows a pin, a hibernated tab's icon shrinks inside a ring.
    private func drawIcon(_ item: TabItem, in frame: CGRect, tint: NSColor, alpha: CGFloat) {
        let image: CGImage? = switch item.icon {
        case .none where item.isPinned && item.tint == nil:
            TabPackIconCache.shared.image(name: .statePinned, tint: tint, size: frame.width, scale: scale)
                ?? TabSymbolCache.shared.image(named: "pin.fill", tint: tint, pointSize: Metrics.smallIconSize, size: frame.width, scale: scale)
        case .none where item.tint != nil:
            TabSymbolCache.shared.image(named: "circle.fill", tint: tint, pointSize: Metrics.smallIconSize * 0.6, size: frame.width, scale: scale)
        case .icon(let name):
            TabPackIconCache.shared.image(name: name, tint: tint, size: frame.width, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: frame.width, size: frame.width, scale: scale)
        default:
            item.icon.groupChipImage(tint: tint, size: frame.width, scale: scale)
        }
        var box = frame
        if item.isDormant {
            Palette.textTertiary.setStroke()
            let ring = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            box = frame.insetBy(dx: frame.width * 0.2, dy: frame.height * 0.2)
        }
        if let image { draw(image, in: box, alpha: alpha) }
    }

    func draw(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func drawTitle(_ title: String, font: NSFont, color: NSColor, in rect: CGRect) {
        guard rect.width > 4 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = ceil(font.ascender - font.descender + font.leading)
        text.draw(with: CGRect(x: rect.minX, y: pixel(rect.midY - height / 2), width: rect.width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawClose(in rect: CGRect, hovered: Bool, pressed: Bool) {
        if hovered || pressed, let fill = ChromeHover.fillColor(.init(hovering: hovered, pressed: pressed)) {
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
        let side = TabTunables.closeGlyphSize.value
        let glyph = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: glyph.minX, y: glyph.minY))
        path.line(to: CGPoint(x: glyph.maxX, y: glyph.maxY))
        path.move(to: CGPoint(x: glyph.maxX, y: glyph.minY))
        path.line(to: CGPoint(x: glyph.minX, y: glyph.maxY))
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        (hovered ? Palette.textPrimary : Palette.textSecondary).setStroke()
        path.stroke()
    }

    // MARK: Groups and New Tab

    /// Chrome's group chip as a row: a solid pill of the group's color with its name, and a chevron
    /// that says whether its tabs show. Collapsed to icons, a short bar of the color.
    private func drawGroupHeader(_ group: TabGroupItem, row: Row) {
        let frame = viewRect(row.frame)
        guard showsTitles else {
            group.tint.headerFill.setFill()
            let bar = CGRect(x: frame.minX + Metrics.space1, y: frame.midY - 1.5, width: max(0, frame.width - 2 * Metrics.space1), height: 3)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        if hovered == row.kind, DesignSettings.shared.showsHoverFills {
            Palette.hoverFill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius).fill()
        }
        let chevron = Metrics.smallIconSize
        let pillHeight = max(Metrics.space5, frame.height - 2 * Metrics.space1)
        let font = Typography.caption
        let name = group.name as NSString
        let iconSize = metrics.iconSize * 0.8
        let iconWidth = group.icon == nil ? 0 : iconSize + Metrics.space1
        let textWidth = group.name.isEmpty ? 0 : ceil(name.size(withAttributes: [.font: font]).width)
        let maxPill = max(pillHeight, frame.width - chevron - 2 * Metrics.space2)
        let pillWidth = textWidth + iconWidth == 0 ? pillHeight : min(maxPill, textWidth + iconWidth + 2 * TabTunables.groupChipPadding.value)
        let pill = CGRect(x: frame.minX, y: pixel(frame.midY - pillHeight / 2), width: pillWidth, height: pillHeight)
        group.tint.chipFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        var x = pill.minX + TabTunables.groupChipPadding.value
        if let icon = group.icon, let image = icon.groupChipImage(tint: Palette.textPrimary, size: iconSize, scale: scale) {
            draw(image, in: CGRect(x: x, y: pill.midY - iconSize / 2, width: iconSize, height: iconSize))
            x += iconWidth
        }
        if textWidth > 0 {
            drawTitle(group.name, font: font, color: Palette.textPrimary,
                      in: CGRect(x: x, y: pill.minY, width: max(0, pill.maxX - TabTunables.groupChipPadding.value - x), height: pill.height))
        }
        let symbol = group.isCollapsed ? "chevron.right" : "chevron.down"
        if let image = TabSymbolCache.shared.image(named: symbol, tint: Palette.textSecondary, pointSize: Metrics.smallIconSize * 0.75,
                                                   size: chevron, scale: scale) {
            draw(image, in: CGRect(x: frame.maxX - Metrics.space1 - chevron, y: frame.midY - chevron / 2, width: chevron, height: chevron))
        }
    }

    private func drawNewTab(_ row: Row) {
        let frame = viewRect(row.frame)
        let isHovered = hovered == row.kind
        if isHovered || press?.target == .newTab, let fill = ChromeHover.fillColor(.init(hovering: isHovered, pressed: press?.target == .newTab)) {
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: metrics.cornerRadius, yRadius: metrics.cornerRadius).fill()
        }
        let color = isHovered ? Palette.textPrimary : Palette.textSecondary
        let size = metrics.iconSize
        let center = CGPoint(x: showsTitles ? frame.minX + metrics.padding + size / 2 : frame.midX, y: frame.midY)
        let arm = Metrics.space2 + Metrics.space1 / 2
        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: pixel(center.x - arm), y: pixel(center.y)))
        plus.line(to: CGPoint(x: pixel(center.x + arm), y: pixel(center.y)))
        plus.move(to: CGPoint(x: pixel(center.x), y: pixel(center.y - arm)))
        plus.line(to: CGPoint(x: pixel(center.x), y: pixel(center.y + arm)))
        plus.lineWidth = 1.25
        plus.lineCapStyle = .round
        color.setStroke()
        plus.stroke()
        guard showsTitles else { return }
        let titleX = center.x + size / 2 + TabTunables.iconTitleSpacing.value
        drawTitle(Strings.axNewTab, font: Typography.body, color: color,
                  in: CGRect(x: titleX, y: frame.minY, width: max(0, frame.maxX - metrics.padding - titleX), height: frame.height))
    }

    func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    // MARK: Buttons

    /// A tab row's close button (content coordinates) while it shows: titles shown, the tab closable,
    /// and the row hovered or selected (Chrome's vertical tabs).
    func closeFrame(_ row: Row) -> CGRect? {
        guard showsTitles, case .tab(let id) = row.kind, let item = model.tab(id), item.isClosable,
              hovered == row.kind || id == model.selectedID else { return nil }
        let side = TabTunables.closeButtonSize.value
        return CGRect(x: row.frame.maxX - Metrics.space1 - side, y: row.frame.midY - side / 2, width: side, height: side)
    }

    /// A tab row's speaker button (content coordinates) while the tab plays sound or is muted.
    func audioFrame(_ row: Row) -> CGRect? {
        guard showsTitles, case .tab(let id) = row.kind, model.tab(id)?.audio != nil else { return nil }
        let side = TabTunables.closeButtonSize.value
        let end = closeFrame(row)?.minX ?? row.frame.maxX - Metrics.space1
        return CGRect(x: end - side, y: row.frame.midY - side / 2, width: side, height: side)
    }
}
