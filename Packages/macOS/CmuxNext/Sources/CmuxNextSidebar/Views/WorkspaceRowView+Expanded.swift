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
        let top = (b.height - th - CGFloat(lines) * (lineGap + sh)) / 2
        return (th, sh, top, isExpanded ? top + th / 2 : b.height / 2)
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
        timeLabel.frame = NSRect(x: trailing - w, y: cy - height / 2, width: w, height: height)
        return trailing - w - Metrics.space2
    }

    /// The pin button of an expanded row, with the menu button (hover, not
    /// renaming): left of it, Pin or Unpin by the row's section, fading in
    /// and out in place with it. Returns its minX while it shows.
    func layoutPin(showMore: Bool, control: CGFloat, fades: Bool) -> CGFloat? {
        let pinned = isExpanded ? isPinned?() : nil
        setHoverShown(pinButton, showMore && pinned != nil, fades: fades)
        guard let pinned else { return nil }
        (pinButton.icon, pinButton.label) = pinned ? (.statePinned, Strings.unpinWorkspace) : (.actionPin, Strings.pinWorkspace)
        pinButton.frame = moreButton.frame.offsetBy(dx: -(control + Metrics.space1), dy: 0)
        return showMore ? pinButton.frame.minX : nil
    }

    /// The title, the second line and the meta line, top to bottom from `top`.
    func layoutTextLines(x: CGFloat, inset: CGFloat, titleWidth: CGFloat, width: CGFloat, head b: NSRect,
                         top: CGFloat, title th: CGFloat, line sh: CGFloat) {
        title.frame = NSRect(x: x + inset, y: top, width: titleWidth, height: th)
        let lineWidth = isExpanded ? max(0, b.width - Metrics.space3 - x) : width
        subtitle.isHidden = !hasSubtitle
        subtitle.frame = NSRect(x: x, y: top + th + lineGap, width: lineWidth, height: sh)
        metaLabel.isHidden = !hasMeta
        metaLabel.frame = NSRect(x: x, y: (hasSubtitle ? subtitle.frame.maxY : top + th) + lineGap, width: lineWidth, height: sh)
    }
}
