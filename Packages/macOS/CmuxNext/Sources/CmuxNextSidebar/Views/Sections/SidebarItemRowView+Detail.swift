import AppKit
import CmuxNextDesign

// A row's detail (`SidebarItemInfo.detail`): quieter words after the title on the same line, so the
// row keeps its one height. A remote chat's row names its machine there (Lawrence's flat remote rows,
// db986014: "plain rows with a machine caption"); nothing else sets it, so other rows draw as before.
extension SidebarItemRowView {
    /// A row look draws the detail; tiles, icons and the inline chip draw none.
    var showsDetail: Bool { info.detail?.isEmpty == false && (style == .builtIn || style == .list) }

    func configureDetail() {
        detail.stringValue = showsDetail ? info.detail ?? "" : ""
        detail.isHidden = !showsDetail
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
    }

    /// VoiceOver's words for the item in every look: the detail follows the title, drawn or not (a tile
    /// draws only the title, so it says the machine here and in its tooltip).
    var accessibilityTitleWithDetail: String { info.titleWithDetail }

    /// The title from `x` to `end`, and the detail just after the title's text. The detail keeps its
    /// own width up to two fifths of the room, so the title truncates first.
    func layoutTitle(x: CGFloat, y: CGFloat, height: CGFloat, end: CGFloat) {
        let room = max(0, end - x)
        guard showsDetail else {
            detail.frame = .zero
            title.frame = NSRect(x: x, y: y, width: room, height: height)
            return
        }
        detail.font = SidebarStyle.subtitleFont
        let gap = Metrics.space2
        // Frame widths, the labels' 2 pt side padding included (`naturalSize`, not the intrinsic text size).
        let (titleNatural, detailNatural) = (ceil(title.naturalSize.width), detail.naturalSize)
        let detailWidth = min(ceil(detailNatural.width), max(room * 2 / 5, room - titleNatural - gap))
        let titleWidth = min(titleNatural, max(0, room - detailWidth - gap))
        title.frame = NSRect(x: x, y: y, width: titleWidth, height: height)
        let detailHeight = ceil(detailNatural.height)
        // On the title's baseline: the smaller words sit on the same line as the title's.
        let baseline = y + title.firstBaselineOffsetFromTop
        detail.frame = NSRect(x: x + titleWidth + gap, y: (baseline - detail.firstBaselineOffsetFromTop).rounded(),
                              width: max(0, detailWidth), height: detailHeight)
    }

    /// The drawn detail (tests).
    var detailText: String? { detail.isHidden ? nil : detail.stringValue }
    /// The detail's frame (tests).
    var detailFrame: CGRect { detail.isHidden ? .zero : detail.frame }
}
