import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// An AppKit label cell draws its text this far inside its frame; the
    /// marquee label draws at its edge, so it sits this much further in.
    static let labelInset = Metrics.space1
    /// Room for a two-digit count, so 9 to 10 tabs moves nothing else.
    static let countWidth: CGFloat = 18
    /// The PR badge never takes more than this from the title.
    static let badgeMaxWidth: CGFloat = 72

    /// The state the activity indicator draws: `activity`, or with the `.status` row badge the
    /// row's most urgent state, a done mark for unread work included.
    func rowStatus(_ ws: SidebarWorkspace, activity: StatusIndicatorState) -> StatusIndicatorState {
        statusSide == nil ? activity : WorkspaceRowBadges(unread: ws.unread, activity: activity).first ?? .idle
    }

    /// Places a status icon on the left (the `.status` row badge) in a fixed slot at `x`, shown or
    /// not, so every row's title starts on one column, and returns where the icon or title starts.
    func layoutLeadingStatus(at x: CGFloat, centerY: CGFloat) -> CGFloat {
        guard statusSide == .left else { return x }
        activity.frame = statusGlyphFrame(trailing: x + SidebarStyle.statusGlyphSize, centerY: centerY)
        return x + SidebarStyle.statusGlyphSize + Metrics.space2
    }

    /// The status mark's frame (the shared indicator, or the agent mark standing in for it) ending
    /// at `trailing`: as tall as the unread badge, centered on `centerY`, the line the badge and
    /// the row's other trailing marks share (a compact row's middle, a one-line row's and a
    /// two-line row's alike; an expanded row's title line), on the pixel grid. Leo 2026-10-14:
    /// a mark on the title's capitals sat above the badge ("why is it superscript?"), and a
    /// two-line row centers it on the whole row.
    func statusGlyphFrame(trailing: CGFloat, centerY: CGFloat) -> NSRect {
        let side = SidebarStyle.statusGlyphSize
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snapped(trailing - side), y: snapped(centerY - side / 2), width: side, height: side)
    }

    /// The agent mark's image size: the status mark's when it stands in for the status, the
    /// indicator size when it sits beside the title, so its brand variant matches the box it fills.
    var agentMarkSize: CGFloat {
        agentMarkVariant == .replacesStatus ? SidebarStyle.statusGlyphSize : SidebarStyle.indicatorSize
    }
}
