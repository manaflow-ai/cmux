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
        addSubview(agentTag) // the corner controls (layoutAgentTag); the zoom indicator joins above it at the first zoom
        return Task { [weak self] in
            for await presence in ObservationStream({ model.tabs.first { $0.id == model.selectedID }?.presence }) {
                self?.agentTag.configure(presence)
                self?.needsLayout = true
            }
        }
    }

    /// The corner controls at the content's top-right: the zoom indicator under the strip and the
    /// pane's header (a toolbar's buttons, a chat's header), the agent tag left of it.
    func layoutAgentTag() {
        let host = contentHost.frame, top = barPosition == .top && !isBandActive && stripView.frame.height > 0 && host.minY < stripView.frame.maxY ? stripView.frame.maxY : host.minY
        if zoomIndicator == nil, stripView.model.zoomsSelected { zoomIndicator = PaneZoomIndicatorView(model: stripView.model) } // its first zoom lays the pane out
        if let zoomIndicator, zoomIndicator.superview !== self { addSubview(zoomIndicator, positioned: .above, relativeTo: agentTag) }
        let trailing = zoomIndicator?.place(in: host, top: max(top, paneHeaderHeight)) ?? 0
        guard !agentTag.isHidden, !isBandActive else { agentTag.frame = .zero; return }
        agentTag.place(in: host, top: top, trailing: trailing)
    }
}
