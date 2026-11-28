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
        let y = statusBlock.isHidden ? bottom - height - 1
            : head + statusBlock.barSlotY(metrics) + (metrics.progressBarHeight - height) / 2
        progressTrack.isHidden = false
        progressTrack.frame = CGRect(x: x, y: y, width: width, height: height)
        progressTrack.cornerRadius = height / 2
        progressFill.frame = CGRect(x: 0, y: 0, width: width * (progress.value ?? 1), height: height)
        progressFill.cornerRadius = height / 2
        performWithTheme {
            progressTrack.backgroundColor = Palette.textTertiary.withAlphaComponent(0.25).cgColor
            let color = progress.isError ? Palette.danger : Palette.accent
            progressFill.backgroundColor = (progress.value == nil ? color.withAlphaComponent(0.4) : color).cgColor
        }
    }
}
