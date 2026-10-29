import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

extension WorkspaceRowView {
    /// Where an NSTextField label with this text would sit (inline rename
    /// aligns its field to it): the glyphs start one cell inset inside it.
    override var titleFrame: NSRect { title.frame.insetBy(dx: -Self.labelInset, dy: 0) }
    override var titleFont: NSFont { title.font }
    override func setTitleHidden(_ hidden: Bool) {
        renaming = hidden
        title.isHidden = hidden
        needsLayout = true
        if hidden { title.stopMarquee() }
    }

    /// An AppKit label cell draws its text this far inside its frame; the
    /// marquee label draws at its edge, so it sits this much further in.
    static let labelInset = Metrics.space1
    /// Room for a two-digit count, so 9 to 10 tabs moves nothing else.
    static let countWidth: CGFloat = 18
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
            if let machine { machineMark.setTint(machine.color) }
            prBadge.setColor(Palette.textSecondary)
            tintSessionTree()
            let waits = if case .waiting = activityState { true } else { false }
            agentMark.setTint(waits ? Palette.attention : Palette.textSecondary)
            // Fills only, no borders: drop target, selection, multi-selection or on screen, hover.
            let fill = isDropTarget || isSelected ? Palette.selectionFill : isSecondarySelected || isOnScreen ? Palette.secondarySelectionFill
                : isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : nil
            paintFill(fill)
            (rowBadge.ringColor, rowBadge.chipColor) = (Self.badgeBackdrop(fill), Palette.sidebarStep.cgColor)
            // The sidebar's own tonal step, once more: a bar a step apart.
            placeholderBar.layer?.backgroundColor = Palette.sidebarStep.cgColor
        }
    }

    override func layout() {
        super.layout()
        let full = layoutBounds
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
        let indent = CGFloat(treeDepth) * SidebarStyle.treeIndent // a started workspace sits in under its parent
        let (th, sh, top, cy) = textMetrics(head: b)
        // A custom workspace icon or favicon takes the leading slot; without one the title starts
        // at the leading inset (no default kind glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0 // text only: no kind glyph or agent brand (WORKSPACE-ROWS-NO-DEFAULT-ICON)
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?, .emoji?, .favicon?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: cy - side / 2, width: side, height: side)
        layoutTreeLine(leading: SidebarStyle.horizontalInset)

        // Trailing cluster, right to left: the dot or spinner on the trailing column, the disclosure
        // and the tab count (fixed slots, the same with or without hover), close-or-badge, then
        // the other marks.
        var trailing = b.width - SidebarStyle.horizontalInset // the pill's own inset, as the text's (Leo 2026-10-13)
        let control = SidebarStyle.controlSize
        // Lawrence msg 11914: the row's dot or spinner owns the trailing column (the x the group
        // header chevron and every band item's dot share) whatever else the row shows; the
        // disclosure, the counts, the keycap and the hover close and more sit left of it.
        let markReplacesStatus = !agentMark.isHidden && agentMarkVariant == .replacesStatus
        activity.isHidden = markReplacesStatus
        let columnMark = layoutColumnMark(cy: cy, rowWidth: b.width, markReplacesStatus: markReplacesStatus)
        if let columnMark { trailing = columnMark.trailing }
        // The hover controls give way at once as the pointer leaves to a column mark, or to the unread count the close
        // covers (the `trailing` badge style), so a mark fading back never draws beside a control fading out (Leo
        // 2026-10-28: "just don't show the spinner" while hovering).
        let controlFades = fades && columnMark == nil && !badge.state.isUnread
        // The chevron shows on hover and on the selected row only (cx-fo2t); its slot stays.
        setHoverShown(disclosureButton, !(disclosure == nil || disclosure == .empty || isShowingPlaceholder || !(isHovered || isSelected)), fades: fades)
        if disclosure != nil {
            disclosureButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        tabCount.isHidden = count == nil || isShowingPlaceholder
        if count != nil {
            let h = ceil(tabCount.intrinsicContentSize.height)
            tabCount.frame = NSRect(x: trailing - Self.countWidth, y: cy - h / 2, width: Self.countWidth, height: h)
            trailing -= Self.countWidth + Metrics.space2
        }
        prBadge.isHidden = badgeText == nil || isShowingPlaceholder
        if badgeText != nil {
            let size = prBadge.intrinsicContentSize
            let w = min(ceil(size.width), Self.badgeMaxWidth), h = ceil(size.height)
            // The text ends at `trailing`; the frame adds the label's padding around it.
            prBadge.frame = prBadge.frame(forAlignmentRect: NSRect(x: trailing - w, y: cy - h / 2, width: w, height: h))
            trailing -= w + Metrics.space2
        }
        trailing = layoutTreeFold(trailing: trailing, cy: cy, control: control, fades: fades)
        trailing = layoutRollUp(trailing: trailing, cy: cy)
        trailing = layoutPullRequests(trailing: trailing, cy: cy)
        // Lawrence 2026-10-11 ("Overlay with fade"): the title keeps its full
        // width at rest and on hover. The x and the more button draw over the
        // end of the title, which fades out before them (an alpha mask), so
        // nothing moves. Marks under them hide while they show. An unread
        // badge keeps its slot at rest, and the action that lands there on
        // hover hides it.
        let showClose = isHovered && !isShowingPlaceholder && isClosable
        let showMore = !isPlaceholderRow && onMore != nil && isHovered && !renaming
        setHoverShown(closeButton, showClose, fades: controlFades)
        setHoverShown(badge, !(showClose || (showMore && !isClosable) || !badge.state.isUnread), fades: fades)
        // The keycap of one of the first rows takes the unread mark's slot when there is no mark.
        setHoverShown(keycap, keycap.number != nil && !badge.state.isUnread && !(showClose || (showMore && !isClosable)), fades: fades)
        var slot: CGFloat = 0
        if !badge.state.isUnread, keycap.number != nil { slot = layoutKeycap(trailing: trailing, cy: cy, control: control) }
        if badge.state.isUnread {
            let w = badge.preferredWidth
            let h = badge.state == .dot ? SidebarStyle.dotSize : SidebarStyle.badgeHeight
            let pad = badge.state == .dot ? Metrics.space2 : 0
            badge.frame = NSRect(x: trailing - w - pad, y: cy - h / 2, width: w, height: h)
            slot = max(control, w + pad)
        }
        closeButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
        if slot > 0 { trailing -= slot + Metrics.space2 }
        trailing = layoutTime(trailing: trailing, cy: cy, height: sh)
        // The menu button, on hover only, left of the x (or in its place on a
        // row that cannot close). Hidden (not only clear) when it does not
        // show; VoiceOver uses the row's custom action.
        setHoverShown(moreButton, showMore, fades: controlFades)
        moreButton.frame = closeButton.frame.offsetBy(dx: isClosable && !isShowingPlaceholder ? -(control + Metrics.space1) : 0, dy: 0)
        let markGivesWay = placeCloseSpot(columnMark: columnMark?.view, rowWidth: b.width, cy: cy, control: control,
                                          showClose: showClose, showMore: showMore)
        let pinStart = layoutPin(showMore: showMore, control: control, fades: controlFades)
        let overlayStart = [showClose ? closeButton.frame.minX : nil, showMore ? moreButton.frame.minX : nil, pinStart].compactMap { $0 }.min()
        let ind = SidebarStyle.indicatorSize
        if markReplacesStatus, columnMark?.view !== agentMark {
            agentMark.frame = statusGlyphFrame(trailing: trailing, centerY: cy)
            trailing = agentMark.frame.minX - Metrics.space2
        } else if activity.showsGlyph, columnMark?.view !== activity {
            activity.frame = statusGlyphFrame(trailing: trailing, centerY: cy)
            trailing = activity.frame.minX - Metrics.space2
        }
        if !mutedMark.isHidden {
            mutedMark.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        if !audioButton.isHidden {
            audioButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
            trailing -= control + Metrics.space1
        }
        if !presenceDots.isHidden {
            let w = presenceDots.preferredWidth
            presenceDots.frame = NSRect(x: trailing - w, y: isExpanded ? top : 0, width: w, height: isExpanded ? th : b.height)
            trailing -= w + Metrics.space2
        }

        // Without an icon the title starts at the leading inset; with one, after it (`titleTextX`).
        let swatch: Bool = if case .swatch? = iconKind { true } else { false }
        var textX = SidebarStyle.titleTextX(leading: leading, iconSide: side, swatch: swatch) - Self.labelInset
        if !agentMark.isHidden && agentMarkVariant == .besideTitle {
            agentMark.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
            textX = agentMark.frame.maxX + Metrics.space1
        }
        if !machineMark.isHidden {
            machineMark.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
            textX = machineMark.frame.maxX + Metrics.space1
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
        title.leadingPadding = textX + inset - (side > 0 ? icon.frame.maxX : indent)
        title.fadeWidth = SidebarStyle.titleFadeWidth
        let titleWidth = max(0, textW - inset) // draws at its edge, so it runs to `trailing`
        layoutTextLines(x: textX, inset: inset, titleWidth: titleWidth, width: textW, head: b, top: top, title: th, line: sh)
        // The hover actions draw over the text's end: the title and second
        // line fade out before them (alpha masks, every backdrop), and the
        // marks they cover hide while they show.
        let fade = SidebarStyle.titleFadeWidth
        title.setTrailingOcclusion(overlayStart.map { max(0, title.frame.maxX - ($0 - Metrics.space1)) } ?? 0, animated: fades)
        updateCalmTitleTip()
        subtitle.wantsLayer = true
        subtitle.setTrailingFade(occlusion: overlayStart.map { max(0, subtitle.frame.maxX - ($0 - Metrics.space1)) } ?? 0, fade: fade, animated: fades)
        for mark in [activity, rowBadge, agentMark, mutedMark, machineMark, audioButton, presenceDots, timeLabel] as [NSView] {
            // The column's mark gives way while the hover controls show; so does a status spinner left of it.
            let status = mark === activity || (mark === agentMark && markReplacesStatus)
            let covered = mark === columnMark?.view ? markGivesWay
                : (status && overlayStart != nil) || overlayStart.map { mark.frame.maxX > $0 - Metrics.space1 } == true
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
