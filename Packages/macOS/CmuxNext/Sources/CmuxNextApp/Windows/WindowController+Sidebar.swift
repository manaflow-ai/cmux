import AppKit
import CmuxNextDesign
import CmuxNextPages

extension WindowController {
    /// The sidebar's shown state reaches the top row: the incognito badge after the traffic lights,
    /// and the window controls that collapse while the sidebar is hidden (nxdog41). Strips under
    /// the top row relay out with the controls, animated (`WindowRootView+CornerReveal`).
    func observeSidebarHidden() {
        root.onWindowControlsChange = { [weak self] _ in self?.relayoutTopRowStrips() }
        let model = sidebar.model
        sidebarObservation = Task { [weak self] in
            for await hidden in Observations({ model.isHidden }) {
                guard let self else { return }
                if hidden { services.hoverCards.dismiss(.action) }
                root.showsTitlebarBadge = hidden && root.titlebarBadge != nil
                root.sidebarHidden = hidden
                root.layoutSubtreeIfNeeded()
                relayoutTopRowStrips()
                pagesDidChangeChrome()
            }
        }
    }

    /// Strips under the traffic lights recompute their inset (inside an animation group when the
    /// window controls change, so the tabs slide).
    private func relayoutTopRowStrips() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            pane.view.stripView.updateWindowControlsAvoidance()
            pane.view.stripView.layoutSubtreeIfNeeded()
        }
    }

    /// Marks this window incognito: the badge shows in the sidebar header,
    /// and in the top row after the traffic lights while the sidebar is
    /// hidden (strips under it start after it).
    func showIncognitoBadge() {
        sidebar.container.sidebarView.titlebarAccessory = IncognitoBadgeView()
        root.titlebarBadge = IncognitoBadgeView()
        root.showsTitlebarBadge = sidebar.model.isHidden
        root.needsLayout = true
    }

    /// Full screen keeps the window's controls as they are (no collapse).
    func windowDidEnterFullScreen(_ notification: Notification) { root.applyCornerReveal() }
    func windowDidExitFullScreen(_ notification: Notification) { root.applyCornerReveal() }

    /// Pages in this window read the sidebar state (`data-app-sidebar`).
    private func pagesDidChangeChrome() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            for key in services.pages.tabIDs(in: pane.paneKey) + pane.pane.tabs.filter({ $0.page != nil }).map(\.id) {
                (services.pages.existingView(key)?.content as? PageWebView)?.windowDidChangeChrome()
            }
        }
    }
}
