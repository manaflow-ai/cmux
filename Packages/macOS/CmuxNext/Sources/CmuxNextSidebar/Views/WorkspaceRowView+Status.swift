import AppKit
import CmuxNextDesign
import QuartzCore

extension WorkspaceRowView {
    /// Lays out the chat's subagent lines under the status block (`head`, the flipped y they start at), on the
    /// title's text column (`textX`), and the head fill over the rest of the row.
    func layoutSubagents(textX: CGFloat, head: CGFloat, full: NSRect) {
        headFill.frame = CGRect(x: full.minX, y: full.minY, width: full.width, height: max(0, head - full.minY))
        headFill.cornerRadius = fillCornerRadius
        guard !subagentsView.isHidden else { return }
        subagentsView.textX = textX - full.minX
        subagentsView.indent = SidebarStyle.treeIndent
        subagentsView.trailingInset = Metrics.space3
        subagentsView.frame = NSRect(x: full.minX, y: head, width: full.width, height: subagentsHeight)
        subagentsView.needsLayout = true
    }

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
