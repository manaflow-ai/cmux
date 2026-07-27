internal import Foundation

/// The v1 bonsplit pane commands (`list_panes` / `list_pane_surfaces` /
/// `focus_pane` / `focus_surface_by_panel` / `drag_surface_to_split` /
/// `new_pane`) and the misc v1 surface ops (`new_surface` / `close_surface` /
/// `reload_config` / `refresh_surfaces` / `surface_health`), lifted
/// byte-faithfully from the former `TerminalController` bodies.
extension ControlCommandCoordinator {
    // MARK: - Pane listings / focus

    /// `list_panes` — list the selected workspace's panes.
    func sidebarListPanes() -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        guard let snapshot = sidebarContext?.controlSidebarPaneList() else {
            return "ERROR: No tab selected"
        }
        let lines = snapshot.paneIDs.enumerated().map { index, paneID in
            let selected = paneID == snapshot.focusedPaneID ? "*" : " "
            let tabCount = snapshot.tabCounts[index]
            return "\(selected) \(index): \(paneID.uuidString) [\(tabCount) tabs]"
        }
        return lines.isEmpty ? "No panes" : lines.joined(separator: "\n")
    }

    /// `list_pane_surfaces` — list one pane's bonsplit tabs.
    func sidebarListPaneSurfaces(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        // Parse --pane=<pane-id|index> argument (UUID preferred).
        var paneArg: String?
        for part in args.split(separator: " ") {
            if part.hasPrefix("--pane=") {
                paneArg = String(part.dropFirst(7))
                break
            }
        }

        switch sidebarContext?.controlSidebarPaneSurfaces(paneArg: paneArg) ?? .noTabSelected {
        case .noTabSelected:
            return "ERROR: No tab selected"
        case .paneNotFound:
            return "ERROR: Pane not found"
        case .noPaneTarget:
            return "ERROR: No pane to list tabs from"
        case .rows(let rows):
            let lines = rows.enumerated().map { index, row in
                let selected = row.isSelected ? "*" : " "
                let panelIdStr = row.panelIDString ?? "unknown"
                return "\(selected) \(index): \(row.title) [panel:\(panelIdStr)]"
            }
            return lines.isEmpty ? "No tabs in pane" : lines.joined(separator: "\n")
        }
    }

    /// `focus_pane` — focus a pane by UUID or index.
    func sidebarFocusPane(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let paneArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneArg.isEmpty else { return "ERROR: Usage: focus_pane <pane_id>" }

        return sidebarContext?.controlSidebarFocusPane(paneArg: paneArg) ?? false
            ? "OK"
            : "ERROR: Pane not found"
    }

    /// `focus_surface_by_panel` — focus a surface by its panel UUID.
    func sidebarFocusSurfaceByPanel(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let tabArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabArg.isEmpty else { return "ERROR: Usage: focus_surface_by_panel <panel_id>" }

        guard let panelUUID = UUID(uuidString: tabArg),
              sidebarContext?.controlSidebarFocusSurfaceByPanel(panelID: panelUUID) ?? false else {
            return "ERROR: Panel not found"
        }
        return "OK"
    }

    // MARK: - Drag to split / new pane

    /// `drag_surface_to_split` — move a surface into a new pane (stable-ref
    /// targets forward to the shared app-side `v2SurfaceSplitOff` body).
    func sidebarDragSurfaceToSplit(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: drag_surface_to_split <id|idx> <left|right|up|down>" }

        let surfaceArg = parts[0]
        let directionArg = parts[1]
        guard let direction = ControlSidebarSplitDirectionV1.parse(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let orientationIsHorizontal = direction.isHorizontal
        let insertFirst = direction.insertFirst

        sidebarContext?.controlSidebarRefreshKnownRefs()
        if let stableSurfaceId = uuid(["surface_id": .string(surfaceArg)], "surface_id") {
            switch sidebarContext?.controlSidebarSplitOffSurface(
                surfaceID: stableSurfaceId,
                directionRawValue: directionArg
            ) {
            case .ok(let paneID):
                return paneID.isEmpty ? "OK" : "OK \(paneID)"
            case .error(let message):
                return "ERROR: \(message)"
            case nil:
                return "ERROR: Failed to move surface"
            }
        }

        switch sidebarContext?.controlSidebarDragSurfaceToSplit(
            surfaceArg: surfaceArg,
            orientationIsHorizontal: orientationIsHorizontal,
            insertFirst: insertFirst
        ) {
        case .noTabSelected:
            return "ERROR: No tab selected"
        case .surfaceNotFound:
            return "ERROR: Surface not found"
        case .splitFailed:
            return "ERROR: Failed to split pane"
        case .moved(let newPaneID):
            return "OK \(newPaneID.uuidString)"
        case nil:
            return "ERROR: Failed to move surface"
        }
    }

    /// `new_pane` — split a new terminal/browser pane off the focused panel.
    func sidebarNewPane(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        // Parse arguments: --type=terminal|browser --direction=left|right|up|down --url=...
        var isBrowser = false
        var direction: ControlSidebarSplitDirectionV1 = .right
        var urlRaw: String? = nil
        var url: URL? = nil
        var invalidDirection = false

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                isBrowser = typeStr == "browser"
            } else if partStr.hasPrefix("--direction=") {
                let dirStr = String(partStr.dropFirst(12))
                if let parsed = ControlSidebarSplitDirectionV1.parse(dirStr) {
                    direction = parsed
                } else {
                    invalidDirection = true
                }
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                urlRaw = urlStr.isEmpty ? nil : urlStr
                url = urlRaw.flatMap { URL(string: $0) }
            }
        }

        if invalidDirection {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }
        if isBrowser, !(browserPanelContext?.controlBrowserPanelAvailabilityEnabled() ?? true) {
            return browserPanelOpenExternallyWhenDisabled(rawURL: urlRaw, url: url)
        }

        switch sidebarContext?.controlSidebarCreatePaneSplit(
            isBrowser: isBrowser,
            orientationIsHorizontal: direction.isHorizontal,
            insertFirst: direction.insertFirst,
            url: url
        ) ?? .failed {
        case .created(let newPanelID):
            return "OK \(newPanelID.uuidString)"
        case .routedToRemote:
            return "OK routed-to-remote-tmux"
        case .mirrorInsertFirstRejected:
            return "ERROR: direction left/up is not supported in a remote tmux mirror workspace"
        case .failed:
            return "ERROR: Failed to create pane"
        }
    }

    // MARK: - New / close surface

    /// `new_surface` — create a terminal/browser surface in a pane.
    func sidebarNewSurface(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        // Parse arguments: --type=terminal|browser --pane=<pane_id> --url=...
        var isBrowser = false
        var paneArg: String? = nil
        var urlRaw: String? = nil
        var url: URL? = nil

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                isBrowser = typeStr == "browser"
            } else if partStr.hasPrefix("--pane=") {
                paneArg = String(partStr.dropFirst(7))
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                urlRaw = urlStr.isEmpty ? nil : urlStr
                url = urlRaw.flatMap { URL(string: $0) }
            }
        }
        if isBrowser, !(browserPanelContext?.controlBrowserPanelAvailabilityEnabled() ?? true) {
            return browserPanelOpenExternallyWhenDisabled(rawURL: urlRaw, url: url)
        }

        switch sidebarContext?.controlSidebarNewSurface(isBrowser: isBrowser, paneArg: paneArg, url: url) ?? .noTabSelected {
        case .noTabSelected, .failed:
            return "ERROR: Failed to create tab"
        case .paneNotFound:
            return "ERROR: Pane not found"
        case .created(let id):
            return "OK \(id.uuidString)"
        case .routedToRemote:
            return "OK routed-to-remote-tmux"
        }
    }

    /// `close_surface` — close a surface (focused surface when no argument).
    func sidebarCloseSurface(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sidebarContext?.controlSidebarCloseSurface(surfaceArg: trimmed.isEmpty ? nil : trimmed) ?? .noTabSelected {
        case .noTabSelected, .closeFailed:
            return "ERROR: Failed to close surface"
        case .surfaceNotFound:
            return "ERROR: Surface not found"
        case .lastSurface:
            return "ERROR: Cannot close the last surface"
        case .closed:
            return "OK"
        }
    }

    // MARK: - Misc ops

    /// `reload_config` — reload the Ghostty configuration.
    func sidebarReloadConfig(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty else {
            return "ERROR: Usage: reload_config"
        }
        sidebarContext?.controlSidebarReloadConfig()
        return "OK Reloaded config"
    }

    /// `refresh_surfaces` — force-refresh the selected workspace's terminals.
    func sidebarRefreshSurfaces() -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        let refreshedCount = sidebarContext?.controlSidebarRefreshSurfaces() ?? 0
        return "OK Refreshed \(refreshedCount) surfaces"
    }

    /// `surface_health` — per-panel hosting diagnostics.
    func sidebarSurfaceHealth(_ args: String) -> String {
        guard sidebarContext?.controlSidebarTabManagerAvailable() ?? false else {
            return "ERROR: TabManager not available"
        }
        guard let rows = sidebarContext?.controlSidebarSurfaceHealth(tabArg: args) else {
            return "ERROR: Tab not found"
        }
        let lines = rows.enumerated().map { index, row -> String in
            let panelId = row.panelID.uuidString
            let type = row.typeRawValue
            switch row.kind {
            case .terminal(let inWindow, let portalHosted, let viewDepth):
                return "\(index): \(panelId) type=\(type) in_window=\(inWindow) portal=\(portalHosted) view_depth=\(viewDepth)"
            case .browser(let inWindow):
                return "\(index): \(panelId) type=\(type) in_window=\(inWindow)"
            case .other:
                return "\(index): \(panelId) type=\(type) in_window=unknown"
            }
        }
        return lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
    }
}
