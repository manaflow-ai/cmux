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
    }

    override func updateLayer() {
        performWithTheme {
            title.textColor = Palette.textPrimary
            subtitle.setColor(Palette.textSecondary); [timeLabel, metaLabel].forEach { $0.setColor(Palette.textTertiary) }
            tabCount.setColor(Palette.textTertiary)
            mutedMark.setTint(Palette.textTertiary)
            prBadge.setColor(Palette.textSecondary)
            let waits = if case .waiting = activityState { true } else { false }
            agentMark.setTint(waits ? Palette.attention : Palette.textSecondary)
            // Fills only, no borders: drop target, selection, multi-selection, hover.
            let fill = isDropTarget || isSelected ? Palette.selectionFill : isSecondarySelected ? Palette.secondarySelectionFill
                : isHovered && !isPlaceholderRow ? Palette.hoverFill : nil
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

        // Members indent under their group header; the members' line is
        // one layer per group under the rows (SidebarListView+GroupLines).
        let indent: CGFloat = grouped ? SidebarStyle.groupMemberIndent : 0
        let (th, sh, top, cy) = textMetrics(head: b)
        // A custom workspace icon takes the leading slot; without one the
        // title starts at the leading inset (no default kind glyph).
        let leading = SidebarStyle.horizontalInset + indent
        let side: CGFloat
        switch iconKind {
        case nil: side = 0 // text only: no kind glyph or agent brand (WORKSPACE-ROWS-NO-DEFAULT-ICON)
        case .swatch?: side = SidebarStyle.dotSize + Metrics.space1
        case .symbol?, .emoji?, .favicon?: side = SidebarStyle.iconBox
        }
        icon.frame = NSRect(x: leading, y: cy - side / 2, width: side, height: side)

        // Trailing cluster, right to left: the disclosure and the tab count
        // (fixed slots, the same with or without hover), close-or-badge, then
        // activity.
        var trailing = b.width - SidebarStyle.horizontalInset // the pill's own inset, as the text's (Leo 2026-10-13)
        let control = SidebarStyle.controlSize
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
            prBadge.frame = NSRect(x: trailing - w, y: cy - h / 2, width: w, height: h)
            trailing -= w + Metrics.space2
        }
        // Lawrence 2026-10-11 ("Overlay with fade"): the title keeps its full
        // width at rest and on hover. The x and the more button draw over the
        // end of the title, which fades out before them (an alpha mask), so
        // nothing moves. Marks under them hide while they show. An unread
        // badge keeps its slot at rest, and the action that lands there on
        // hover hides it.
        let showClose = isHovered && !isShowingPlaceholder && isClosable
        let showMore = !isPlaceholderRow && onMore != nil && isHovered && !renaming
        setHoverShown(closeButton, showClose, fades: fades)
        setHoverShown(badge, !(showClose || (showMore && !isClosable) || !badge.state.isUnread), fades: fades)
        var slot: CGFloat = 0
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
        setHoverShown(moreButton, showMore, fades: fades)
        moreButton.frame = closeButton.frame.offsetBy(dx: isClosable && !isShowingPlaceholder ? -(control + Metrics.space1) : 0, dy: 0)
        let pinStart = layoutPin(showMore: showMore, control: control, fades: fades)
        let overlayStart = [showClose ? closeButton.frame.minX : nil, showMore ? moreButton.frame.minX : nil, pinStart].compactMap { $0 }.min()
        let ind = SidebarStyle.indicatorSize
        trailing = layoutRowBadge(trailing: trailing, cy: cy)
        let markReplacesStatus = !agentMark.isHidden && agentMarkVariant == .replacesStatus
        activity.isHidden = markReplacesStatus
        if markReplacesStatus {
            agentMark.frame = statusGlyphFrame(trailing: trailing, centerY: cy)
            trailing = agentMark.frame.minX - Metrics.space2
        } else if activity.showsGlyph {
            activity.frame = statusGlyphFrame(trailing: trailing, centerY: cy)
            trailing = activity.frame.minX - Metrics.space2
        }
        if !mutedMark.isHidden {
            mutedMark.frame = NSRect(x: trailing - ind, y: cy - ind / 2, width: ind, height: ind)
            trailing -= ind + Metrics.space2
        }
        if !presenceDots.isHidden {
            let w = presenceDots.preferredWidth
            presenceDots.frame = NSRect(x: trailing - w, y: isExpanded ? top : 0, width: w, height: isExpanded ? th : b.height)
            trailing -= w + Metrics.space2
        }

        // The title's text starts a Chrome-like 6 pt after the icon's drawing (a favicon or an
        // emoji draws at `kindGlyphSize`, centered in its box; Lawrence 2026-10-19: "slightly too
        // much space between the favicon and the name"); without an icon, at `leading`.
        let iconTextGap: CGFloat = switch iconKind {
        case .swatch?: Metrics.space3 // a color dot keeps its spacing
        default: Metrics.space3 - Self.labelInset - max(0, (side - SidebarStyle.kindGlyphSize) / 2)
        }
        var textX = side > 0 ? icon.frame.maxX + iconTextGap : leading - Self.labelInset
        if !agentMark.isHidden && agentMarkVariant == .besideTitle {
            agentMark.frame = NSRect(x: textX + Self.labelInset, y: cy - ind / 2, width: ind, height: ind)
            textX = agentMark.frame.maxX + Metrics.space1
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
        subtitle.wantsLayer = true
        subtitle.setTrailingFade(occlusion: overlayStart.map { max(0, subtitle.frame.maxX - ($0 - Metrics.space1)) } ?? 0, fade: fade, animated: fades)
        for mark in [activity, rowBadge, agentMark, mutedMark, presenceDots, timeLabel] as [NSView] {
            fadeOpacity(mark, to: overlayStart.map { mark.frame.maxX > $0 - Metrics.space1 } == true ? 0 : 1, fades: fades)
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
