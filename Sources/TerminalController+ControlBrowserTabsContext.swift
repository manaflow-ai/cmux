import AppKit
import CmuxControlSocket
import CmuxPanes
import Foundation

/// The live-app half of the main-actor browser-tab lifecycle commands
/// (`browser.tab.new`, `browser.tab.list`, `browser.tab.switch`,
/// `browser.tab.close`). The coordinator owns the param parsing and `JSONValue`
/// payload shaping; these witnesses perform the `TabManager` / `Workspace` /
/// `BrowserPanel` reach, byte-faithful to the former `v2BrowserTabNew` /
/// `v2BrowserTabList` / `v2BrowserTabSwitch` / `v2BrowserTabClose` bodies.
///
/// Each witness re-runs the legacy `v2ResolveTabManager` → `v2ResolveWorkspace`
/// head (over the Foundation-bridged params) and the same pane/index/surface
/// resolution precedence, then reports each outcome as a typed Sendable value
/// the coordinator maps back to the exact legacy `.ok`/`.err`. The disabled-
/// browser external-open fallback used by `browser.tab.new` reuses the shared
/// `v2BrowserDisabledExternalOpenResult` logic, reproduced here as the four
/// typed disabled-external outcomes (identical to `browser.open_split`).
extension TerminalController {
    // MARK: - tab.list

    func controlBrowserTabList(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabListResolution {
        let foundation = params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: foundation) else {
            return .tabManagerUnavailable
        }

        var resolution: ControlBrowserTabListResolution = .workspaceNotFound
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: foundation, tabManager: tabManager) else { return }
            let browserPanels = orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let rows: [ControlBrowserTabRow] = browserPanels.enumerated().map { index, panel in
                ControlBrowserTabRow(
                    surfaceID: panel.id,
                    index: index,
                    title: panel.displayTitle,
                    url: panel.currentURL?.absoluteString ?? "",
                    focused: panel.id == ws.focusedPanelId,
                    paneID: ws.paneId(forPanelId: panel.id)?.id
                )
            }
            resolution = .resolved(
                workspaceID: ws.id,
                focusedSurfaceID: ws.focusedPanelId,
                tabs: rows
            )
        }
        return resolution
    }

    // MARK: - tab.new

    func controlBrowserTabNew(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors,
        rawURLString: String?
    ) -> ControlBrowserTabNewResolution {
        let foundation = params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: foundation) else {
            return .tabManagerUnavailable
        }

        let urlStr = rawURLString
        let url = urlStr.flatMap(URL.init(string:))
        guard BrowserAvailabilitySettings.isEnabled() else {
            return browserTabDisabledExternalResolution(rawURL: urlStr, url: url, tabManager: tabManager)
        }

        var resolution: ControlBrowserTabNewResolution = .createFailed
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: foundation, tabManager: tabManager) else {
                resolution = .workspaceNotFound
                return
            }
            let paneUUID = v2UUID(foundation, "pane_id")
                ?? v2UUID(foundation, "target_pane_id")
                ?? (v2UUID(foundation, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                resolution = .paneNotFound
                return
            }

            guard let panel = ws.newBrowserSurface(
                inPane: pane,
                url: url,
                focus: true,
                creationPolicy: .automationPreload
            ) else {
                resolution = .createFailed
                return
            }
            resolution = .resolved(
                workspaceID: ws.id,
                paneID: pane.id,
                surfaceID: panel.id,
                url: panel.currentURL?.absoluteString ?? ""
            )
        }
        return resolution
    }

    /// The typed twin of `v2BrowserDisabledExternalOpenResult` for the
    /// `browser.tab.new` disabled-browser fallback: the legacy body forwarded to
    /// that shared helper, whose four outcomes (invalid URL, no URL, external
    /// open failed, opened externally) are reproduced here.
    private func browserTabDisabledExternalResolution(
        rawURL: String?,
        url: URL?,
        tabManager: TabManager?
    ) -> ControlBrowserTabNewResolution {
        if let rawURL, url == nil {
            return .disabledExternalInvalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .disabledExternalNoURL
        }

        var resolution: ControlBrowserTabNewResolution = .disabledExternalOpenFailed(url: url.absoluteString)
        v2MainSync {
            guard NSWorkspace.shared.open(url) else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            resolution = .disabledExternalOpened(windowID: windowId, url: url.absoluteString)
        }
        return resolution
    }

    // MARK: - tab.switch

    func controlBrowserTabSwitch(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabSwitchResolution {
        let foundation = params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: foundation) else {
            return .tabManagerUnavailable
        }

        var resolution: ControlBrowserTabSwitchResolution = .browserTabNotFound
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: foundation, tabManager: tabManager) else {
                resolution = .workspaceNotFound
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(foundation, "target_surface_id") ?? v2UUID(foundation, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(foundation, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return v2UUID(foundation, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                resolution = .browserTabNotFound
                return
            }

            ws.focusPanel(targetId)
            resolution = .resolved(workspaceID: ws.id, surfaceID: targetId)
        }
        return resolution
    }

    // MARK: - tab.close

    func controlBrowserTabClose(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabCloseResolution {
        let foundation = params.mapValues(\.foundationObject)
        guard let tabManager = v2ResolveTabManager(params: foundation) else {
            return .tabManagerUnavailable
        }

        var resolution: ControlBrowserTabCloseResolution = .browserTabNotFound
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: foundation, tabManager: tabManager) else {
                resolution = .workspaceNotFound
                return
            }

            let browserIds = orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                resolution = .noBrowserTabs
                return
            }

            let targetId: UUID? = {
                if let explicit = v2UUID(foundation, "target_surface_id") ?? v2UUID(foundation, "tab_id") {
                    return explicit
                }
                if let idx = v2Int(foundation, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = v2UUID(foundation, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                resolution = .browserTabNotFound
                return
            }

            if ws.panels.count <= 1 {
                resolution = .cannotCloseLastSurface
                return
            }

            let ok = ws.closeSurfaceRecordingHistory(surfaceId: targetId, force: true)
            resolution = ok
                ? .resolved(workspaceID: ws.id, surfaceID: targetId)
                : .closeFailed(surfaceID: targetId)
        }
        return resolution
    }
}
