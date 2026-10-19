import AppKit
import CmuxNextDesign
import QuartzCore

extension WorkspaceRowView {
    /// Lays out the status block below the head (`head`, the flipped y the
    /// name lines end at) and the progress bar: in the block's slot before
    /// the progress label, else at the row's bottom edge (`bottom`).
    func layoutStatus(x: CGFloat, width: CGFloat, head: CGFloat, bottom: CGFloat) {
        statusBlock.frame = NSRect(x: x, y: head, width: width, height: statusHeight)
        guard let progress else {
            progressTrack.isHidden = true
            return
        }
        let metrics = SidebarLayoutMetrics.standard
        let height: CGFloat = 2
        // Without a status block the bar sits inside the pill, one step above its bottom edge, and
        // spans the content (the row's own inset on both sides), not the pill's edge (#20409).
        let inset = SidebarStyle.horizontalInset + (grouped ? SidebarStyle.groupMemberIndent : 0)
        let frame = statusBlock.isHidden
            ? CGRect(x: inset, y: bottom - height - Metrics.space1, width: max(0, layoutBounds.width - SidebarStyle.horizontalInset - inset), height: height)
            : CGRect(x: x, y: head + statusBlock.barSlotY(metrics) + (metrics.progressBarHeight - height) / 2, width: width, height: height)
        progressTrack.isHidden = false
        progressTrack.frame = frame
        progressTrack.cornerRadius = height / 2
        progressFill.frame = CGRect(x: 0, y: 0, width: frame.width * (progress.value ?? 1), height: height)
        progressFill.cornerRadius = height / 2
        performWithTheme {
            progressTrack.backgroundColor = Palette.textTertiary.withAlphaComponent(0.18).cgColor
            let color = progress.isError ? Palette.danger : Palette.accent
            progressFill.backgroundColor = (progress.value == nil ? color.withAlphaComponent(0.4) : color).cgColor
        }
    }
}
