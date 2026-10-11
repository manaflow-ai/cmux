import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The progress bar under the row (`SidebarWorkspace.progress`).
    func layoutProgress(x: CGFloat, width: CGFloat, bottom: CGFloat) {
        guard let progress else {
            progressTrack.isHidden = true
            return
        }
        let height: CGFloat = 2
        progressTrack.isHidden = false
        progressTrack.frame = CGRect(x: x, y: isFlipped ? bottom - height - 1 : 1, width: width, height: height)
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
