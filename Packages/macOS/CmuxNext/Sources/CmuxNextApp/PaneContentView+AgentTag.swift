import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextWakeups

/// The agent name tag over the pane's content (cx-gg84): the presence of the
/// strip's selected tab, at the content's top-right (prompts and text start
/// on the left). Not over a browser whose band holds the strip. A Chromium page draws in
/// its own child window above the pane, so the tag shows over terminals and
/// WebKit pages; the tab chip's dot covers Chromium tabs.
extension PaneContentView {
    /// Follows the selected tab's presence while the pane shows; a hidden pane reads it once on show.
    func observeAgentTag(_ model: TabStripModel, on work: MainWorkScheduler) -> VisibleObservation<TabPresence?> {
        addSubview(agentTag)
        return VisibleObservation(node, owner: "PaneContentView.agentTag", on: work) {
            model.selectedID.flatMap { model.tab($0)?.presence }
        } apply: { [weak self] presence in
            self?.agentTag.configure(presence)
            // invalidate: the presence changed (an Equatable observation applies a new value only); the pane places the tag.
            self?.needsLayout = true
        }
    }

    func layoutAgentTag() {
        guard !agentTag.isHidden, !isBandActive else {
            agentTag.frame = .zero
            return
        }
        let inset = Metrics.space2
        let host = contentHost.frame
        let size = agentTag.fittingSize(maxWidth: max(0, host.width / 2 - inset))
        agentTag.frame = NSRect(x: host.maxX - inset - size.width, y: (ChromeTunables.tabRowTools.value && barPosition == .top && !isBandActive && !stripView.isHidden && host.minY < stripView.frame.maxY ? stripView.frame.maxY : host.minY) + inset, width: size.width, height: size.height)
    }
}
