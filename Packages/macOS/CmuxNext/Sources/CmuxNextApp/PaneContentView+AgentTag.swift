import AppKit
import CmuxNextAgentPane
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

    /// The corner controls at the content's top-right: the zoom indicator under the strip (no tab bar controls) and the
    /// pane's header (a toolbar's buttons, a chat's header), the agent tag left of it.
    func layoutAgentTag() {
        let host = contentHost.frame, top = barPosition == .top && !isBandActive && stripView.frame.height > 0 && host.minY < stripView.frame.maxY ? stripView.frame.maxY : host.minY
        if zoomIndicator == nil, stripView.model.zoomsSelected { zoomIndicator = PaneZoomIndicatorView(model: stripView.model) } // its first zoom lays the pane out
        if let zoomIndicator, zoomIndicator.superview !== self { addSubview(zoomIndicator, positioned: .above, relativeTo: agentTag) }
        let trailing = zoomIndicator?.place(in: host, top: max(top, paneHeaderHeight), elsewhere: toolbar.map { !$0.view.isHidden && $0.view.zoomed } ?? false) ?? 0 // shown in the tab bar's trailing slot when the bar shows
        let occupied = terminalHistoryButton?.place(in: host, top: top, trailing: trailing) ?? trailing
        guard !agentTag.isHidden, !isBandActive else { agentTag.frame = .zero; return }
        agentTag.place(in: host, top: top, trailing: occupied)
    }
}

extension PaneController {
    func showTerminalHistoryLink(in content: TabContent?) {
        let key = stripModel.selectedID.flatMap(stripModel.tab)?.terminalHistoryKey
        guard DesignSettings.shared.experiment("terminalHistory"), case .terminal = content, let key else { // Settings > Experiments > Terminal Agent History, off by default (Leo's UI hold, 2026-11-24)
            view.terminalHistoryButton?.discard()
            view.terminalHistoryButton = nil
            return
        }
        let source = TerminalHistorySource(key: key, cwd: selectedTab?.cwd)
        guard view.terminalHistoryButton?.source != source else { return }
        view.terminalHistoryButton?.discard()
        let button = TerminalHistoryButton(source: source, environment: QuitAgents.environment(services)) { [weak self] in
            guard let self, let id = stripModel.selectedID, currentTabKey == id.rawValue,
                  stripModel.tab(id)?.terminalHistoryKey == source.key else { return }
            WebPageTab.openTerminalHistory(source, in: self)
        }
        view.terminalHistoryButton = button
        view.addSubview(button, positioned: .above, relativeTo: view.agentTag)
        view.needsLayout = true
    }
}
