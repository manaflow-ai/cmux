import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextTabs

/// The agent name tag over the pane's content (cx-gg84): the presence of the
/// strip's selected tab, at the content's top-right (prompts and text start
/// on the left). Not over a browser whose band holds the strip. A Chromium page draws in
/// its own child window above the pane, so the tag shows over terminals and
/// WebKit pages; the tab chip's dot covers Chromium tabs.
extension PaneContentView {
    func observeAgentTag(_ model: TabStripModel) -> Task<Void, Never> {
        [agentTag, zoomIndicator].forEach(addSubview) // the corner controls (layoutAgentTag)
        return Task { [weak self] in
            for await presence in ObservationStream({ model.tabs.first { $0.id == model.selectedID }?.presence }) {
                self?.agentTag.configure(presence)
                self?.needsLayout = true
            }
        }
    }

    /// The corner controls at the content's top-right: the zoom indicator under the strip (no tab bar controls) and the
    /// pane's header (a toolbar's buttons, a chat's header), the agent tag left of it.
    func layoutAgentTag() {
        let host = contentHost.frame, top = barPosition == .top && !isBandActive && stripView.frame.height > 0 && host.minY < stripView.frame.maxY ? stripView.frame.maxY : host.minY
        let trailing = zoomIndicator.place(in: host, top: max(top, paneHeaderHeight), elsewhere: toolbar.map { !$0.view.isHidden && $0.view.zoomed } ?? false) // shown left of "…" when the bar shows
        guard !agentTag.isHidden, !isBandActive else { agentTag.frame = .zero; return }
        agentTag.place(in: host, top: top, trailing: trailing)
    }
}
