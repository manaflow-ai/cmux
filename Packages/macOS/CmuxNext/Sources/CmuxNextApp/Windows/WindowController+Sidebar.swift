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
            self?.homePageWindowControlsChanged()
        }
        // The Home page's header follows the lights after any top-row layout (a launch places
        // the page and the lights after the list first laid out, with no resize of the list).
        root.onTopRowLayout = { [weak self] in self?.homePageWindowControlsChanged() }
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

    /// Strips under the traffic lights recompute their inset.
    func relayoutTopRowStrips() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            pane.view.stripView.updateWindowControlsAvoidance()
            pane.view.stripView.layoutSubtreeIfNeeded()
        }
        homePageWindowControlsChanged()
    }

    /// The Home page slides under or out from under the traffic lights with the sidebar without
    /// a resize of its list: the list's header re-reads them (Messages' header under the lights).
    func homePageWindowControlsChanged() {
        (topPages.views[.home] as? TopHomePageView)?.split.windowControlsMoved()
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
