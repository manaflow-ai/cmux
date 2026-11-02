import AppKit
import CmuxNextDesign

/// Expanded rows (`sidebar.density`, cx-13w3; T3 Code / Codex style): the
/// text lines stack centered in the head, and an expanded row's icon and
/// trailing marks center on the title's line instead of on the head. The
/// age of the last change sits on that line at rest (the hover actions draw
/// over it), and the second and meta lines run under the marks to the row's end.
extension WorkspaceRowView {
    /// The title and line heights, the flipped y the stack starts at, and the
    /// y the icon and trailing marks center on.
    func textMetrics(head b: NSRect) -> (title: CGFloat, line: CGFloat, top: CGFloat, center: CGFloat) {
        let th = ceil(title.intrinsicContentSize.height)
        let sh = SidebarTunables.evenRowText.value ? SidebarStyle.detailLineHeight : ceil(subtitle.intrinsicContentSize.height)
        let lines = (hasSubtitle ? 1 : 0) + (hasMeta ? 1 : 0)
        let stackTop = (b.height - th - CGFloat(lines) * (lineGap + sh)) / 2
        // The title centers its capitals on its line of the stack (#27598).
        let titleCenter = stackTop + th / 2
        let top = SidebarStyle.columns(rowWidth: b.width).textOriginY(centerY: titleCenter, baseline: title.font.ascender,
                                                                    capHeight: title.font.capHeight)
        // The icon and the trailing marks center on the whole row, one line or two (Leo 2026-10-14: "wait that's
        // not centered? why is it superscript?"); only an expanded row puts them on its title's line.
        return (th, sh, top, isExpanded ? titleCenter : b.midY)
    }

    var hasMeta: Bool { isExpanded && !metaLabel.stringValue.isEmpty }

    /// Between stacked text lines: none when each detail line adds exactly its own height to the row
    /// (`SidebarDensityTokens.rowHeightWithSubtitle`); the labels' own line spacing separates them.
    var lineGap: CGFloat { SidebarTunables.evenRowText.value ? 0 : Metrics.space1 }

    /// Lays out the age (or a one-line status) left of `trailing` and returns the new trailing edge.
    func layoutTime(trailing: CGFloat, cy: CGFloat, height: CGFloat) -> CGFloat {
        timeLabel.isHidden = timeText == nil || isShowingPlaceholder
        guard !timeLabel.isHidden else { return trailing }
        // The text's own width too: a time today ("1:26 AM") came out a few points short and ended in "…".
        // A status there (`trailingStatus`) truncates at 40% of the row; the name keeps the rest.
        let w = min(ceil(max(timeLabel.intrinsicContentSize.width, timeLabel.attributedStringValue.size().width + 2 * Self.labelInset)),
                    (bounds.width * 0.4).rounded(.down))
        let columns = SidebarStyle.columns(rowWidth: layoutBounds.width)
        timeLabel.frame = columns.trailingFrame(before: trailing, centerY: cy, size: CGSize(width: w, height: height))
        timeLabel.frame.origin.y = SidebarStyle.textY(timeLabel, centerY: cy)
        return columns.trailingEdge(before: timeLabel.frame)
    }

    /// The Unpin button of an expanded pinned row, with the menu button (hover,
    /// not renaming): left of it, fading in and out in place with it. Returns
    /// its minX while it shows. An unpinned row draws no pin, at rest or on
    /// hover; Pin Workspace stays in its ⋮ menu (Leo 2026-10-21: "no empty pin
    /// symbol by default").
    func layoutPin(rowWidth: CGFloat, showMore: Bool, control: CGFloat, fades: Bool) -> CGFloat? {
        let pinned = isExpanded && isPinned?() == true
        setHoverShown(pinButton, showMore && pinned, fades: fades)
        guard pinned else { return nil }
        (pinButton.icon, pinButton.label) = (.statePinned, Strings.unpinWorkspace)
        if SidebarTunables.rowCloseSpot.value.atEnd {
            let center = SidebarStyle.trailingColumnCenterX(rowWidth: rowWidth)
            let nextSlot = Int(round((center - moreButton.frame.midX) / SidebarStyle.trailingSlotPitch)) + 1
            pinButton.frame = trailingActionFrame(rowWidth: rowWidth, cy: moreButton.frame.midY, control: control, minimumSlot: nextSlot)
        } else {
            pinButton.frame = moreButton.frame.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
        }
        return showMore ? pinButton.frame.minX : nil
    }

    /// The title, the second line and the meta line, top to bottom from `top`.
    func layoutTextLines(x: CGFloat, inset: CGFloat, titleWidth: CGFloat, width: CGFloat, head b: NSRect,
                         top: CGFloat, title th: CGFloat, line sh: CGFloat) {
        title.frame = NSRect(x: x + inset, y: top, width: titleWidth, height: th)
        let lineWidth = isExpanded ? max(0, b.width - Metrics.space3 - x) : width
        // The second and meta lines stack under the title's line box, so a two-line row keeps a one-line row's room
        // below its last line (Leo 2026-10-20, `SidebarRowLineSpacingTests`). Stepping them by the title's capital
        // center instead put the second line about a point lower and ate that room.
        subtitle.isHidden = !hasSubtitle
        subtitle.frame = NSRect(x: x, y: top + th + lineGap, width: lineWidth, height: sh)
        metaLabel.isHidden = !hasMeta
        metaLabel.frame = NSRect(x: x, y: (hasSubtitle ? subtitle.frame.maxY : top + th) + lineGap, width: lineWidth, height: sh)
    }
}
