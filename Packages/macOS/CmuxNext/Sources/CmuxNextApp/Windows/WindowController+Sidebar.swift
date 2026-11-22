import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextLiveCode
import CmuxNextPages

extension WindowController {
    /// The sidebar's shown state reaches the top row: the incognito badge after the traffic lights
    /// and the toggle's glyph. Strips under the top row relay out after it.
    func observeSidebarHidden() {
        // Each frame of the sidebar's width animation collapses or restores the
        // toolbar band; strips under it follow in the same layout pass.
        root.onToolbarBandPresenceChange = { [weak self] in
            for pane in self?.content?.panes.values.map({ $0 }) ?? [] { pane.view.stripView.updateWindowControlsAvoidance() }
            WindowControlsAvoiders.refresh(in: self?.window)
        }
        // The Home page rides the sidebar's slide inside the main pane card with no layout of its
        // own (a hide sizes it once at the start): every move of the card, its last frame
        // included, has its header re-read the traffic lights (no change, no work).
        root.onMainPaneMove = { [weak self] in WindowControlsAvoiders.refresh(in: self?.window) }
        // The host pressure indicator, then extensions' status items (cmux.status/1), join the top row after the band and badge (cmuxterm-hq#2995).
        let topRowChanged = { [weak self] in
            self?.root.needsLayout = true
            self?.root.layoutSubtreeIfNeeded()
            self?.relayoutTopRowStrips()
        }
        root.hostPressureIndicator = HostPressureIndicatorView(services: services, onVisibilityChange: topRowChanged)
        root.extensionStatusStrip = services.apps.client.statusItems.titlebarStrip(onWidthChange: topRowChanged)
        // Swift live mode's mark: in the sidebar's footer, and in the top row while the sidebar is hidden.
        services.liveCode.whenLive { [weak self] in
            self?.sidebar.container.sidebarView.liveModeBadge = LiveModeBadgeView()
            self?.root.liveModeBadge = LiveModeBadgeView()
            self?.relayoutTopRowStrips()
        }
        sidebar.container.sidebarView.healthIndicator = services.healthFeeds.makeIndicator { [weak self] in self?.window } // app health's footer line
        root.sidebarFloat.isAllowed = { [weak self] in self.map { $0.state.page != .home && !$0.root.presentsPage } ?? false }
        let model = sidebar.model
        sidebarObservation = Task { [weak self] in
            for await hidden in ObservationStream({ model.isHidden }) {
                guard let self else { return }
                if let window { services.hoverCards.sidebarHidden(hidden, in: window) }
                root.showsTitlebarBadge = hidden && root.titlebarBadge != nil
                root.sidebarHidden = hidden
                root.layoutSubtreeIfNeeded()
                relayoutTopRowStrips()
                pagesDidChangeChrome()
            }
        }
    }

    /// Strips under the traffic lights recompute their inset.
    func relayoutTopRowStrips() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            pane.view.stripView.updateWindowControlsAvoidance()
            pane.view.stripView.layoutSubtreeIfNeeded()
        }
        WindowControlsAvoiders.refresh(in: window)
    }

    /// Marks this window incognito: the badge shows in the sidebar header,
    /// and in the top row after the traffic lights while the sidebar is
    /// hidden (strips under it start after it).
    func showIncognitoBadge() {
        sidebar.container.sidebarView.titlebarAccessory = IncognitoBadgeView(title: WindowStrings.incognitoBadge, help: WindowStrings.incognitoHelp)
        root.titlebarBadge = IncognitoBadgeView(title: WindowStrings.incognitoBadge, help: WindowStrings.incognitoHelp)
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
