import AppKit
import CmuxNextDesign
import Foundation

/// A working row's running time (Leo 2026-10-20: "4m" when the row is wide): dim, left of the
/// working dot, in place of the age of the last change, and only while the name still fits whole
/// beside it, so a narrow sidebar keeps the row as it was. A one-line status there keeps its place.
/// The hover card shows the time to the second.
extension WorkspaceRowView {
    /// Lays out the running time left of `trailing` and returns the new trailing edge; while it
    /// shows, arms a tick for the next whole minute.
    func layoutElapsed(trailing: CGFloat, textX: CGFloat, cy: CGFloat, height: CGFloat) -> CGFloat {
        let now = Date()
        let since = timeText == nil && !isShowingPlaceholder ? workingSince : nil
        let text = since.flatMap { WorkspaceRowContent.workingElapsed(since: $0, now: now) } ?? ""
        elapsedLabel.setString(text)
        let w = ceil(elapsedLabel.attributedStringValue.size().width + 2 * Self.labelInset)
        let fits = !text.isEmpty && textX + Self.labelInset + title.intrinsicContentSize.width + Metrics.space2 + w <= trailing
        elapsedLabel.isHidden = !fits
        // The first minute shows nothing yet; wake when it ends. A resize or a new state lays out anyway.
        if let since, window != nil, !isHiddenOrHasHiddenAncestor, fits || text.isEmpty {
            let intoMinute = now.timeIntervalSince(since).truncatingRemainder(dividingBy: 60)
            elapsedTicker.scheduleIfIdle(after: .seconds(60 - max(0, intoMinute))) { @MainActor [weak self] in
                self?.needsLayout = true
            }
        } else {
            elapsedTicker.cancel()
        }
        guard fits else { return trailing }
        elapsedLabel.frame = NSRect(x: trailing - w, y: cy - height / 2, width: w, height: height)
        return trailing - w - Metrics.space1
    }

    /// A row taken from the pool stops its tick and lays out again, which re-arms it. A row that
    /// returns to its own workspace keeps its content (`keepsContentOnReturn`), so the start stays.
    func stopElapsed() {
        elapsedTicker.cancel()
        needsLayout = true
    }
}
