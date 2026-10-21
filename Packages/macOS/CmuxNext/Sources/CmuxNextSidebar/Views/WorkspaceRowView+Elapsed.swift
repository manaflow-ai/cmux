import AppKit
import CmuxNextDesign
import Foundation

/// A working row's running time (Leo 2026-10-20: "4m" when the row is wide): dim, left of the
/// working dot, only while the name still fits whole beside it, so a narrow sidebar keeps the row
/// as it was. A row with its own trailing text (an age, a status line) keeps that instead. The
/// hover card shows the time to the second.
extension WorkspaceRowView {
    /// Lays out the running time left of `trailing` and returns the new trailing edge; arms a tick
    /// for the next whole minute while the agent works.
    func layoutElapsed(trailing: CGFloat, textX: CGFloat, cy: CGFloat, height: CGFloat) -> CGFloat {
        let since = timeText == nil && !isShowingPlaceholder ? workingSince : nil
        guard let since, window != nil else {
            elapsedTicker.cancel()
            elapsedLabel.isHidden = true
            return trailing
        }
        let now = Date()
        // The text changes on the minute: wake then, not every second.
        let intoMinute = now.timeIntervalSince(since).truncatingRemainder(dividingBy: 60)
        elapsedTicker.scheduleIfIdle(after: .seconds(60 - max(0, intoMinute))) { @MainActor [weak self] in
            self?.needsLayout = true
        }
        let text = WorkspaceRowContent.workingElapsed(since: since, now: now) ?? ""
        elapsedLabel.setString(text)
        let w = ceil(elapsedLabel.attributedStringValue.size().width + 2 * Self.labelInset)
        let fits = !text.isEmpty && textX + Self.labelInset + title.intrinsicContentSize.width + Metrics.space2 + w <= trailing
        elapsedLabel.isHidden = !fits
        guard fits else { return trailing }
        elapsedLabel.frame = NSRect(x: trailing - w, y: cy - height / 2, width: w, height: height)
        return trailing - w - Metrics.space1
    }
}
