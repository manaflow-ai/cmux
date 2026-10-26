import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages

extension WindowController {
    /// The sidebar's shown state reaches the top row: the incognito badge after the traffic lights
    /// and the toggle's glyph. Strips under the top row relay out after it.
    func observeSidebarHidden() {
        // Each frame of the sidebar's width animation collapses or restores the
        // toolbar band; strips under it follow in the same layout pass.
        root.onToolbarBandPresenceChange = { [weak self] in
            for pane in self?.content?.panes.values.map({ $0 }) ?? [] { pane.view.stripView.updateWindowControlsAvoidance() }
            self?.updateTopRowAvoiders()
        }
        // The host pressure indicator joins the top row after the band and badge (cmuxterm-hq#2995).
        root.hostPressureIndicator = HostPressureIndicatorView(services: services) { [weak self] in
            // Shown or hidden: the top row places it (layoutTitlebarAccessories), then strips avoid it.
            self?.root.needsLayout = true
            self?.root.layoutSubtreeIfNeeded()
            self?.relayoutTopRowStrips()
        }
        let model = sidebar.model
        sidebarObservation = Task { [weak self] in
            for await hidden in ObservationStream({ model.isHidden }) {
                guard let self else { return }
                if hidden { services.hoverCards.suppress(.sidebarHide) }
                else { services.hoverCards.unsuppress(.sidebarHide) }
                if hidden { services.hoverCards.dismiss(.action) }
                root.showsTitlebarBadge = hidden && root.titlebarBadge != nil
                root.sidebarHidden = hidden
                root.layoutSubtreeIfNeeded()
                relayoutTopRowStrips()
                pagesDidChangeChrome()
            }
        }
    }

    /// Strips and other views under the traffic lights recompute their inset.
    func relayoutTopRowStrips() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            pane.view.stripView.updateWindowControlsAvoidance()
            pane.view.stripView.layoutSubtreeIfNeeded()
        }
        updateTopRowAvoiders()
    }

    /// Views with no tab strip that keep clear of the traffic lights (Home's list header in the
    /// docked Home pane, which has no tab bar) re-check where the lights are over them (cmux#25593).
    private func updateTopRowAvoiders() {
        guard let window = window as? ShellWindow else { return }
        window.windowControlsAvoiders.update(in: window)
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

    /// Pages in this window read the sidebar state (`data-app-sidebar`).
    private func pagesDidChangeChrome() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            for key in services.pages.tabIDs(in: pane.paneKey) + pane.pane.tabs.filter({ $0.page != nil }).map(\.id) {
                (services.pages.existingView(key)?.content as? PageWebView)?.windowDidChangeChrome()
            }
        }
    }
}
