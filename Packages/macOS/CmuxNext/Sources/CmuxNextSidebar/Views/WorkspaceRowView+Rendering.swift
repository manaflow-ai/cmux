import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

extension WorkspaceRowView {
    /// Where an NSTextField label with this text would sit (inline rename
    /// aligns its field to it): the glyphs start one cell inset inside it.
    override var titleFrame: NSRect { title.frame.insetBy(dx: -Self.labelInset, dy: 0) }
    override var titleFont: NSFont { title.font }
    /// The marquee label draws its text at its frame's edge, the baseline one ascender (on a whole
    /// pixel) below its top (`ChromeTextLayer`).
    override var titlePenOrigin: NSValue? {
        let scale = window?.backingScaleFactor ?? 2
        return NSValue(point: NSPoint(x: title.frame.minX, y: title.frame.minY + (title.font.ascender * scale).rounded() / scale))
    }
    override var titleInk: NSColor? { title.textColor }
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
        needsLayout = true
        if hidden { title.stopMarquee() }
    }

    /// An AppKit label cell draws its text this far inside its frame; the
    /// marquee label draws at its edge, so it sits this much further in.
    static let labelInset = LayoutGrid.halfStep
    /// Room for a two-digit count, so 9 to 10 tabs moves nothing else.
    static let countWidth: CGFloat = LayoutGrid.iconBox
    /// The PR badge never takes more than this from the title.
    static let badgeMaxWidth: CGFloat = 72

    override func hoverChanged() {
        super.hoverChanged()
        // The x, the more button and the chevron show or hide only in
        // `layout()`, so every hover change asks for one; AppKit coalesces it
        // into the next pass. Skipping it during a scroll or a list apply left
        // a row's controls up after hover cleared (no pointer event follows).
        needsLayout = true
        // During a scroll the pointer is stationary while rows pass under it.
        // A synchronous layout and a marquee for every crossing turn
        // realization into a main-thread hitch, so those wait for real hover.
        let list = superview as? SidebarListView
        let suppressEffects = list?.hoverFollowsScroll == true || list?.suppressHoverEffects == true
        guard isHovered, !renaming, !isPlaceholderRow, !suppressEffects else {
            title.stopMarquee()
            return
        }
        // The x and the more button draw over the title's end behind a fade,
        // so the title keeps its width; a clipped title scrolls. Under Reduce
        // Motion no marquee runs: the workspace hover card shows the whole
        // name (wrapped), so no second popover (a tooltip) shows with it.
        layoutSubtreeIfNeeded()
        title.startMarquee()
        updateCalmTitleTip()
    }

    /// Calm mode (`ui.calm`) runs no marquee and opens no hover card, so a clipped name shows as
    /// the row's themed tooltip instead (the title view takes no hits). Layout sets it too: a
    /// themed tracker added while the pointer is already inside gets no mouseEntered, so it has
    /// to exist before the pointer arrives.
    func updateCalmTitleTip() {
        let calm = DesignSettings.shared.calmMode != .off
        let tip = !calm ? nil : hiddenWorkspaceName.map { $0 + SidebarRowTitleMode.crumb + title.stringValue }
            ?? (title.isTruncated ? title.stringValue : nil)
        if themedToolTip != tip { themedToolTip = tip }
    }

    override func updateLayer() {
        performWithTheme {
            // An idle workspace nobody named reads quiet until it is selected, hovered or busy.
            title.textColor = isQuiet && !isSelected && !isSecondarySelected && !isHovered ? Palette.textSecondary : Palette.textPrimary
            subtitle.setColor(Palette.textSecondary); [timeLabel, metaLabel].forEach { $0.setColor(Palette.textTertiary) }
            if isArchived { // dimmed (archiving-DESIGN.md)
                title.textColor = title.textColor.withAlphaComponent(SidebarStyle.archivedAlpha)
                subtitle.setColor(Palette.textTertiary)
            }
            tabCount.setColor(Palette.textTertiary)
            mutedMark.setTint(Palette.textTertiary)
            usageWarningMark.setTint(Palette.attention)
            // One neutral colour for every machine (Leo 2026-11-01): no per-machine tint on the row's mark.
            machineMark.setTint(Palette.textTertiary)
            prBadge.setColor(Palette.textSecondary)
            tintSessionTree()
            let waits = if case .waiting = activityState { true } else { false }
            agentMark.setTint(waits ? Palette.attention : agentMarkFallbackColor.map(SidebarStyle.color) ?? Palette.textSecondary)
            // Fills, no borders but the focus ring below: drop target, selection, multi-selection or on screen, hover.
            let fill = isDropTarget || isSelected ? Palette.selectionFill : isSecondarySelected || isOnScreen ? Palette.secondarySelectionFill
                : isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : nil
            let painted = colorFill() ?? fill // `workspaceColors.indicatorStyle` (#25653): fill or rail
            paintFill(painted)
            // The one border: the focus ring of the group this row stands for, as its header draws it.
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = isKeyboardFocused ? Metrics.dividerThickness * 1.5 : 0
            (rowBadge.ringColor, rowBadge.chipColor) = (Self.badgeBackdrop(painted), Palette.sidebarStep.cgColor)
            // The sidebar's own tonal step, once more: a bar a step apart.
            placeholderBar.layer?.backgroundColor = Palette.sidebarStep.cgColor
        }
    }

    override func layout() {
        super.layout()
        let full = layoutBounds
        layoutColorRail(in: full)
        // The name lines and the trailing cluster center in the head; the
        // status block, when shown, fills the rest below it.
        let b = NSRect(x: full.minX, y: full.minY, width: full.width, height: full.height - statusHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Entering a row should reveal its controls immediately. Keep the
        // short fade only for clearing them as the pointer leaves.
        let fades = fadesNextHover && !isHovered
        defer { fadesNextHover = false; CATransaction.commit() }

        // A group member's content starts where an ungrouped row's does: no indent for the group
        // (Leo 2026-10-21); the members' line is one layer per group beside the rows
        // (SidebarListView+GroupLines).
        let (th, sh, top, cy) = textMetrics(head: b)
        let columns = SidebarStyle.columns(rowWidth: b.width, depth: treeDepth)
        // A custom workspace icon or favicon takes the leading slot; without one the title starts
        // at the leading inset (no default kind glyph).
        let leading = columns.lead
        // A `leftRail` row keeps its dot's slot empty, so its title stays clear of the rail, where the dot style has it.
        let railSlot = iconKind == nil && rowColor?.style == .leftRail
        let side: CGFloat
        switch iconKind {
        case nil: side = railSlot ? SidebarStyle.dotSize + Metrics.space1 : 0 // text only: no kind glyph (WORKSPACE-ROWS-NO-DEFAULT-ICON)
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?, .emoji?, .favicon?: side = SidebarStyle.iconColumnBox
        }
        // The icon's box starts on lead (where an iconless title would start) and its glyph centers in it; the text
        // column is the grid's, one gap after the box.
        icon.frame = NSRect(x: leading, y: cy - side / 2, width: side, height: side)
        layoutTreeLine(leading: SidebarStyle.columns(rowWidth: b.width).lead)

        // Trailing cluster, right to left: the dot or spinner on the trailing column, the tab
        // count (a fixed slot, the same with or without hover), close-or-badge, then the other marks.
        var trailing = columns.trailingEdge
        let control = SidebarStyle.controlSize
        // Lawrence msg 11914: the row's dot or spinner owns the trailing column (the x the group
        // header chevron and every band item's dot share) whatever else the row shows; the
        // counts, the keycap and the hover close and more sit left of it.
        let markReplacesStatus = !agentMark.isHidden && agentMarkVariant == .replacesStatus
        activity.isHidden = markReplacesStatus
        let columnMark = layoutColumnMark(cy: cy, rowWidth: b.width, markReplacesStatus: markReplacesStatus)
        if let columnMark { trailing = columnMark.trailing }
        // The hover controls give way at once as the pointer leaves to a column mark, or to the unread count the close
        // covers (the `trailing` badge style), so a mark fading back never draws beside a control fading out (Leo
        // 2026-10-28: "just don't show the spinner" while hovering).
        let controlFades = fades && columnMark == nil && !badge.state.isUnread
        tabCount.isHidden = count == nil || isShowingPlaceholder
        if count != nil {
            let h = ceil(tabCount.intrinsicContentSize.height)
            tabCount.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: Self.countWidth, height: h))
            tabCount.frame.origin.y = SidebarStyle.textY(tabCount, centerY: cy)
            trailing = columns.trailingEdge(before: tabCount.frame)
        }
        prBadge.isHidden = badgeText == nil || isShowingPlaceholder
        if badgeText != nil {
            let size = prBadge.intrinsicContentSize
            let w = min(ceil(size.width), Self.badgeMaxWidth), h = ceil(size.height)
            let textFrame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: w, height: h))
            prBadge.frame = prBadge.frame(forAlignmentRect: textFrame)
            prBadge.frame.origin.y = SidebarStyle.textY(prBadge, centerY: cy)
            trailing = columns.trailingEdge(before: prBadge.frame)
        }
        let hoverCloses = isClosable && !(revealsHoverControls && isPinned?() == true)
        let showClose = revealsHoverControls && !isShowingPlaceholder && hoverCloses
        let showMore = !isPlaceholderRow && onMore != nil && revealsHoverControls && !renaming
        // An end action owns the column. Tree controls and chips remain visible and clickable
        // to its left, even when an idle row has no status mark reserving that slot. A row with none
        // of them keeps its rest layout: the title keeps its full width on hover and the controls
        // draw over its faded end (Lawrence 2026-10-11, "Overlay with fade"), so nothing moves.
        let restTrailing = trailing
        if SidebarTunables.rowCloseSpot.value.atEnd, showClose || showMore {
            trailing = min(trailing, SidebarStyle.trailingColumnStart(rowWidth: b.width) - Metrics.space1)
        }
        let reserved = trailing
        trailing = layoutTreeFold(trailing: trailing, cy: cy, control: control, fades: fades)
        trailing = layoutRollUp(trailing: trailing, cy: cy)
        trailing = layoutPullRequests(trailing: trailing, cy: cy)
        if trailing == reserved { trailing = restTrailing }
        // Lawrence 2026-10-11 ("Overlay with fade"): the title keeps its full
        // width at rest and on hover. The x and the more button draw over the
        // end of the title, which fades out before them (an alpha mask), so
        // nothing moves. Marks under them hide while they show. An unread
        // badge keeps its slot at rest, and the action that lands there on
        // hover hides it.
        // A pinned workspace's row draws no x on hover; it closes from its right-click menu (Lawrence msg 19392:
        // "hover on pinned tab should not have close button, should only be able to close in right click"). Its ⋮
        // takes the x's place, as on a row that cannot close. The pin is read only while the controls show.
        setHoverShown(closeButton, showClose, fades: controlFades)
        setHoverShown(badge, !(showClose || (showMore && !hoverCloses) || !badge.state.isUnread), fades: fades)
        // The keycap of one of the first rows takes the unread mark's slot when there is no mark.
        setHoverShown(keycap, keycap.number != nil && !badge.state.isUnread && !(showClose || (showMore && !hoverCloses)), fades: fades)
        var badgeEdge: CGFloat?
        if !badge.state.isUnread, keycap.number != nil {
            _ = layoutKeycap(trailing: trailing, cy: cy, control: control)
            badgeEdge = columns.trailingEdge(before: keycap.frame)
        }
        // An unread dot with the column free is the column's mark (`layoutColumnMark`). Otherwise the dot (8 pt) or
        // the count takes the next slot, a small glyph centered in it.
        if badge.state.isUnread, columnMark?.view !== badge {
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.unreadDotSize : SidebarStyle.badgeHeight
            badge.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: w, height: h))
            badgeEdge = columns.trailingEdge(before: badge.frame)
        }
        closeButton.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: control, height: control))
        if let badgeEdge { trailing = badgeEdge }
        trailing = layoutTime(trailing: trailing, cy: cy, height: sh)
        // The menu button, on hover only, left of the x (or in its place on a
        // row that cannot close). Hidden (not only clear) when it does not
        // show; VoiceOver uses the row's custom action.
        setHoverShown(moreButton, showMore, fades: controlFades)
        moreButton.frame = closeButton.frame.offsetBy(dx: hoverCloses && !isShowingPlaceholder ? -SidebarStyle.trailingSlotPitch : 0, dy: 0)
        let markGivesWay = placeCloseSpot(columnMark: columnMark?.view, rowWidth: b.width, cy: cy, control: control,
                                          showClose: showClose, showMore: showMore)
        let pinStart = layoutPin(rowWidth: b.width, showMore: showMore, control: control, fades: controlFades)
        let overlayStart = [showClose ? closeButton.frame.minX : nil, showMore ? moreButton.frame.minX : nil, pinStart].compactMap { $0 }.min()
        let ind = SidebarStyle.indicatorSize
        if markReplacesStatus, columnMark?.view !== agentMark {
            agentMark.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: SidebarStyle.statusGlyphSize, height: SidebarStyle.statusGlyphSize))
            trailing = columns.trailingEdge(before: agentMark.frame)
        } else if activity.showsGlyph, columnMark?.view !== activity {
            activity.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: SidebarStyle.statusGlyphSize, height: SidebarStyle.statusGlyphSize))
            trailing = columns.trailingEdge(before: activity.frame)
        }
        if !mutedMark.isHidden {
            mutedMark.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: ind, height: ind))
            trailing = columns.trailingEdge(before: mutedMark.frame)
        }
        if !machineMark.isHidden, columnMark?.view !== machineMark {
            // The computer the row runs on: a status mark's box on the trailing column's line, centered on the row
            // (Leo 2026-11-01, on the small tinted cloud before the name: "I HATE HOW SMALL THEY ARE I HATE THAT
            // THEY'RE ON THE LEFT I HATE THAT THEY'RE ON THE BOTTOM"). It gives way to the hover controls as the
            // other marks do.
            machineMark.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: SidebarStyle.statusGlyphSize, height: SidebarStyle.statusGlyphSize))
            trailing = columns.trailingEdge(before: machineMark.frame)
        }
        if !usageWarningMark.isHidden {
            // The triangle takes a status mark's box (the spinner's, `statusGlyphFrame`); with no spinner it is the
            // column's mark (`layoutColumnMark`), centered where every spinner above it centers (Lawrence 2026-10-30:
            // "triangle not aligned, not sure if triangle is even centered": it ended at the row's inset, in a smaller
            // box). It never gives way to the hover controls: while they show it sits just left of them, so a person
            // who hovers the row can still point at it and read its tooltip.
            let onColumn = columnMark?.view === usageWarningMark
            let end = onColumn ? usageWarningMark.frame.maxX : trailing
            let shown = overlayStart.map { min(end, $0 - Metrics.space1) } ?? end
            if !onColumn || shown < end { usageWarningMark.frame = statusGlyphFrame(trailing: shown, centerY: cy) }
            if !onColumn { trailing = usageWarningMark.frame.minX - Metrics.space2 }
        }
        if !audioButton.isHidden {
            audioButton.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: control, height: control))
            trailing = columns.trailingEdge(before: audioButton.frame)
        }
        if !presenceDots.isHidden {
            let w = presenceDots.preferredWidth
            presenceDots.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: w, height: isExpanded ? th : b.height))
            trailing = columns.trailingEdge(before: presenceDots.frame)
        }

        // Without an icon the title starts on lead; with one (or a left rail's kept dot slot), on the text column
        // (`workspaceTitleX`).
        var textX = SidebarStyle.workspaceTitleX(icon: iconKind, treeDepth: treeDepth, reservesColorRail: railSlot)
        if !agentMark.isHidden && agentMarkVariant == .besideTitle {
            agentMark.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
            textX = SidebarStyle.titleXAfterLeadingMark(textX)
        }
        let textW = max(0, trailing - textX)
        let titleArrival = titleArrivalPending || titleArrivalActive
        title.isHidden = renaming || (isShowingPlaceholder && !titleArrival)
        placeholderBar.isHidden = !isShowingPlaceholder && !titleArrival
        let barHeight = SidebarStyle.placeholderBarHeight
        placeholderBar.frame = NSRect(x: textX + Self.labelInset, y: cy - barHeight / 2,
                                      width: max(0, textW - 2 * Self.labelInset) * placeholderFraction, height: barHeight)
        // The marquee fades glyphs out across the padding left of them.
        let inset = Self.labelInset
        title.leadingPadding = textX + inset - (side > 0 ? icon.frame.maxX : columns.lead)
        title.fadeWidth = SidebarStyle.titleFadeWidth
        let titleWidth = max(0, textW - inset) // draws at its edge, so it runs to `trailing`
        layoutTextLines(x: textX, inset: inset, titleWidth: titleWidth, width: textW, head: b, top: top, title: th, line: sh)
        // The hover actions draw over the text's end: the title and second
        // line fade out before them (alpha masks, every backdrop), and the
        // marks they cover hide while they show.
        let fade = SidebarStyle.titleFadeWidth
        let warningStart = usageWarningMark.isHidden ? nil : usageWarningMark.frame.minX
        // The text and marks give way to the controls and to the badge beside them.
        let coverStart = overlayStart.map { min($0, warningStart ?? $0) }
        title.setTrailingOcclusion(coverStart.map { max(0, title.frame.maxX - ($0 - Metrics.space1)) } ?? 0, animated: fades)
        updateCalmTitleTip()
        subtitle.wantsLayer = true
        subtitle.setTrailingFade(occlusion: coverStart.map { max(0, subtitle.frame.maxX - ($0 - Metrics.space1)) } ?? 0, fade: fade, animated: fades)
        for mark in [activity, rowBadge, agentMark, mutedMark, usageWarningMark, machineMark, audioButton, presenceDots, timeLabel, tabCount, prBadge] as [NSView] {
            // The column's mark gives way while the hover controls show; so does a status spinner left of it.
            let status = mark === activity || (mark === agentMark && markReplacesStatus)
            let covered = mark === usageWarningMark ? false : mark === columnMark?.view ? markGivesWay
                : (status && coverStart != nil) || coverStart.map { mark.frame.maxX > $0 - Metrics.space1 } == true
            fadeOpacity(mark, to: covered ? 0 : 1, fades: fades)
        }
        layoutStatus(x: textX, width: max(0, b.width - Metrics.space3 - textX), head: b.maxY, bottom: full.maxY)
        if titleArrivalPending && !titleArrivalScheduled {
            titleArrivalScheduled = true
            CATransaction.setCompletionBlock { [weak self] in self?.startTitleArrival() }
        }
        // No needsDisplay here: `updateLayer` reads no layout value, and configure, hover, selection,
        // drop target and appearance changes mark display themselves. Each display costs AppKit a
        // contents-scale walk to the window (perf round 4: the top display frames while scrolling).
    }
}
