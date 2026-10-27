import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

extension WindowController {
    /// The sidebar's shown state reaches the top row: the incognito badge after the traffic lights
    /// and the toggle's glyph. Strips under the top row relay out after it.
    func observeSidebarHidden() {
        // Each frame of the sidebar's width animation collapses or restores the
        // toolbar band; strips under it follow in the same layout pass.
        root.onToolbarBandPresenceChange = { [weak self] in
            for pane in self?.content?.panes.values.map({ $0 }) ?? [] { pane.view.stripView.updateWindowControlsAvoidance() }
        }
        // A band reveal springs the tab rows it moved from where they showed.
        root.collapsedBand.stripRows = { [weak self] in
            (self?.content?.panes.values.map({ $0 }) ?? []).flatMap { $0.view.stripView.windowControlsRows }
        }
        // The host pressure indicator joins the top row after the band and badge (cmuxterm-hq#2995).
        root.hostPressureIndicator = HostPressureIndicatorView(services: services) { [weak self] in
            // The top row places it (layoutTitlebarAccessories), then strips avoid it.
            // invalidate: the indicator showed, hid or changed width (it calls this on a change only).
            self?.root.needsLayout = true
            // sync-layout: relayoutTopRowStrips reads the indicator's frame the root's layout places.
            self?.root.layoutSubtreeIfNeeded()
            self?.relayoutTopRowStrips()
        }
        let model = sidebar.model
        // A service observation: the hover cards (another owner) and the pages hear it while the window is hidden.
        // The person's toggle applies in the input-response pass, before the frame commits.
        sidebarObservation = ServiceObservation(.visible, owner: "WindowController.sidebarHidden", on: services.mainWork) {
            model.isHidden
        } apply: { [weak self] hidden in
            guard let self else { return }
            if hidden { services.hoverCards.suppress(.sidebarHide) }
            else { services.hoverCards.unsuppress(.sidebarHide) }
            if hidden { services.hoverCards.dismiss(.action) }
            root.showsTitlebarBadge = hidden && root.titlebarBadge != nil
            root.sidebarHidden = hidden
            // sync-layout: relayoutTopRowStrips reads the strips' window frames and the badge the root places.
            root.layoutSubtreeIfNeeded()
            relayoutTopRowStrips()
            pagesDidChangeChrome()
        }
    }

    /// The window recolors when it switches room: view work, on the window's node (a hidden window recolors
    /// when it shows). The room's browser profile for tab badges is model state: it follows while hidden.
    func observeRoom() {
        let state = state
        roomObservation = VisibleObservation(visibility, owner: "WindowController.roomTheme", on: services.mainWork) {
            state.profileID
        } apply: { [weak self] _ in
            guard let self else { return }
            services.themes.windowDidChange(self)
        }
        // Set in the switch's own turn (`WindowState.profileID`), and again when the room's record changes.
        let home = services.machines.local.store
        state.roomBrowserProfileOf = { [weak home] room in home?.profile(room)?.browserProfileID?.rawValue }
        roomBrowserProfileObservation = ServiceObservation(.visible, owner: "WindowController.roomBrowserProfile",
                                                           on: services.mainWork) {
            home.profile(state.profileID)?.browserProfileID
        } apply: { _ in
            state.refreshRoomBrowserProfile()
        }
    }

    /// Strips under the traffic lights recompute their inset. A strip whose
    /// inset changed marks itself (`updateWindowControlsAvoidance`) and lays
    /// out in the window's next pass; nothing in this turn reads its tabs.
    func relayoutTopRowStrips() {
        for pane in content?.panes.values.map({ $0 }) ?? [] {
            pane.view.stripView.updateWindowControlsAvoidance()
        }
    }

    /// Marks this window incognito: the badge shows in the sidebar header,
    /// and in the top row after the traffic lights while the sidebar is
    /// hidden (strips under it start after it).
    func showIncognitoBadge() {
        sidebar.container.sidebarView.titlebarAccessory = IncognitoBadgeView()
        root.titlebarBadge = IncognitoBadgeView()
        // The root lays out for the new badge and for a change of its shown state (both setters).
        root.showsTitlebarBadge = sidebar.model.isHidden
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
