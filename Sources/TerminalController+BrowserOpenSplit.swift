import AppKit
import CmuxBrowser
import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    // Internal (not private): `CloudTreeService.openDesktop/openPort` open the same browser
    // split the socket verb does, so the sidebar, `cmux vm desktop`, and `cmux vm open` share
    // one path.
    func v2BrowserOpenSplit(
        params: [String: Any],
        diffViewerRegistration: DiffViewerSessionPreparation
    ) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        if let error = v2RejectUnresolvedHandles(
            params,
            ["workspace_id", "window_id", "surface_id", "tab_id", "pane_id"]
        ) {
            return error
        }
        let urlStr = v2String(params, "url")
        // Resolve with the same smart logic as browser.navigate (URL, then search fallback)
        // so an unparseable raw string fails loudly instead of silently opening about:blank.
        let url: URL?
        if let urlStr {
            let trimmedURLStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let navigable = resolveBrowserNavigableURL(urlStr) {
                // http/https/file plus host-like inputs (example.com, localhost:3000).
                url = navigable
            } else if let parsed = URL(string: trimmedURLStr), parsed.scheme != nil {
                // Preserve any real-scheme URL the navigable resolver rejects: about:blank,
                // the trusted cmux-diff-viewer:// scheme, and external app/deep-link schemes
                // (mailto:, xcode://, ...). The downstream browser-disabled, external-open, and
                // diff-viewer-registration paths act on the original URL; only scheme-less,
                // non-navigable input should fall through to a search query.
                url = parsed
            } else if let search = BrowserSearchSettingsStore().currentConfiguration.searchURL(query: urlStr) {
                url = search
            } else {
                return .err(
                    code: "invalid_params",
                    message: "Could not resolve URL or search query",
                    data: ["url": urlStr]
                )
            }
        } else {
            url = nil
        }
        let respectExternalOpenRules = v2Bool(params, "respect_external_open_rules") ?? false
        let useTerminalLinkBrowserPlacement = v2Bool(
            params,
            "use_terminal_link_browser_placement"
        ) ?? false

        let profileKeys = ["profile", "profile_id", "profile_name"]
        let suppliedProfileKeys = profileKeys.filter { v2HasNonNullParam(params, $0) }
        if suppliedProfileKeys.count > 1 {
            return .err(
                code: "invalid_params",
                message: BrowserProfileAutomationError.multipleProfileSelectors.description,
                data: ["profile_parameters": suppliedProfileKeys]
            )
        }
        if let invalidProfileKey = profileKeys.first(where: {
            v2HasNonNullParam(params, $0) && v2String(params, $0) == nil
        }) {
            return .err(
                code: "invalid_params",
                message: BrowserProfileAutomationError.invalidProfileSelector.description,
                data: ["profile_parameter": invalidProfileKey]
            )
        }

        let profileSelector = v2String(params, "profile")
            ?? v2String(params, "profile_id")
            ?? v2String(params, "profile_name")
        let preferredProfileID: UUID?
        if let selector = profileSelector {
            switch BrowserProfileStore.shared.resolveProfileSelection(selector) {
            case .matched(let profile):
                preferredProfileID = profile.id
            case .notFound:
                return .err(
                    code: "invalid_params",
                    message: BrowserProfileAutomationError.profileNotFound(selector).description,
                    data: ["profile": selector]
                )
            case .ambiguous(let profiles):
                return .err(
                    code: "invalid_params",
                    message: BrowserProfileAutomationError.ambiguousProfile(selector, profiles).description,
                    data: [
                        "profile": selector,
                        "candidates": profiles.map {
                            ["id": $0.id.uuidString, "name": $0.displayName]
                        },
                    ]
                )
            }
        } else {
            preferredProfileID = nil
        }

        if BrowserAvailabilitySettings.isDisabled() {
            if let profileSelector {
                return .err(
                    code: "invalid_params",
                    message: BrowserProfileAutomationError.browserDisabled.description,
                    data: ["profile": profileSelector]
                )
            }
            if v2IsDiffViewerURL(url) {
                return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
            }
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }
        if let url, let failure = v2BrowserURLAllowlistFailure(for: url) {
            return failure
        }
        if let error = v2RegisterDiffViewerURLIfNeeded(
            params: params,
            url: url,
            preparation: diffViewerRegistration
        ) {
            return error
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser", data: nil)
        v2MainSync {
            let resolution = v2ResolveBrowserSplitContainer(
                params: params,
                tabManager: tabManager
            )
            if let error = resolution.error {
                result = error
                return
            }
            guard let container = resolution.container else {
                result = .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: nil
                )
                return
            }
            if let profileSelector,
               preferredProfileID != nil,
               container.isRemoteWorkspace {
                result = .err(
                    code: "invalid_params",
                    message: BrowserProfileAutomationError.profileUnavailableInRemoteWorkspace.description,
                    data: ["profile": profileSelector]
                )
                return
            }
            if let url,
               respectExternalOpenRules,
               preferredProfileID == nil {
                switch externalNavigationHandler.openConfiguredExternallyResult(url) {
                case .notConfigured:
                    break
                case .failed:
                    result = .err(
                        code: "external_open_failed",
                        message: "Failed to open URL externally",
                        data: ["url": url.absoluteString]
                    )
                    return
                case .opened:
                    let windowId = v2BrowserWindowID(
                        for: container.host,
                        tabManager: tabManager
                    )
                    result = .ok([
                        "window_id": v2OrNull(windowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: windowId),
                        "workspace_id": container.ownerID.uuidString,
                        "workspace_ref": v2Ref(
                            kind: .workspace,
                            uuid: container.ownerID
                        ),
                        "pane_id": v2OrNull(nil),
                        "pane_ref": v2Ref(kind: .pane, uuid: nil),
                        "surface_id": v2OrNull(nil),
                        "surface_ref": v2Ref(kind: .surface, uuid: nil),
                        "created_split": false,
                        "placement_strategy": "external",
                        "opened_externally": true,
                        "url": url.absoluteString
                    ])
                    return
                }
            }
            v2MaybeFocusWindow(for: tabManager)
            switch container {
            case .workspace(let workspace):
                v2MaybeSelectWorkspace(tabManager, workspace: workspace)
            case .dock(let dock) where dock.scope == .workspace:
                if let workspace = tabManager.tabs.first(where: {
                    $0.id == dock.workspaceId
                }) {
                    v2MaybeSelectWorkspace(
                        tabManager,
                        workspace: workspace
                    )
                }
            case .dock:
                break
            }

            let requestedSurfaceId = v2UUID(params, "surface_id")
                ?? v2UUID(params, "tab_id")
            let requestedPaneId = v2UUID(params, "pane_id")
            guard let sourceSurfaceId = container.sourcePanelID(
                requestedSurfaceID: requestedSurfaceId,
                requestedPaneID: requestedPaneId
            ) else {
                if let requestedSurfaceId {
                    result = .err(
                        code: "not_found",
                        message: "Source surface not found",
                        data: [
                            "surface_id": requestedSurfaceId.uuidString,
                        ]
                    )
                } else if let requestedPaneId {
                    result = .err(
                        code: "not_found",
                        message: "Pane has no selected surface",
                        data: ["pane_id": requestedPaneId.uuidString]
                    )
                } else {
                    result = .err(
                        code: "not_found",
                        message: "No focused surface to split",
                        data: nil
                    )
                }
                return
            }
            guard let sourcePane = container.paneID(
                forPanelID: sourceSurfaceId
            ) else {
                result = .err(
                    code: "not_found",
                    message: "Source surface not found",
                    data: ["surface_id": sourceSurfaceId.uuidString]
                )
                return
            }

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            let omnibarVisible = v2Bool(params, "show_omnibar") ?? true
            let transparentBackground = v2Bool(params, "transparent_background") ?? false
            let bypassRemoteProxy = v2Bool(params, "bypass_remote_proxy") ?? v2IsDiffViewerURL(url)
            let preservesSourceSelection = useTerminalLinkBrowserPlacement
                && BrowserLinkOpenSettings.terminalLinkBrowserPlacement() == .samePane
            let request = BrowserSplitRequest(
                url: url,
                focus: focus,
                preferredProfileID: preferredProfileID,
                chromeVisibility: BrowserChromeVisibility(
                    omnibarVisible: omnibarVisible
                ),
                transparentBackground: transparentBackground,
                bypassRemoteProxy: bypassRemoteProxy,
                selectWhenNotFocused: !preservesSourceSelection
            )
            let browserPlacement = useTerminalLinkBrowserPlacement && requestedSurfaceId != nil
                && requestedPaneId == nil && profileSelector == nil && url != nil
                ? BrowserLinkOpenSettings.terminalLinkBrowserPlacement()
                : .reuseOrSplit
            guard let placement = container.openTerminalLink(
                from: sourceSurfaceId,
                request: request,
                placement: browserPlacement
            ) else {
                result = .err(code: "internal_error", message: "Failed to create browser", data: nil)
                return
            }

            let browserPanelId = placement.panel.id
            let targetPaneUUID = container.paneID(
                forPanelID: browserPanelId
            )?.id
            let context = V2BrowserPanelContext(
                host: container.host,
                workspaceId: container.ownerID,
                surfaceId: browserPanelId,
                browserPanel: placement.panel,
                webView: placement.panel.webView
            )
            let payload = v2BrowserActionPayload(
                context,
                tabManager: tabManager,
                extra: [
                    "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                    "source_surface_id": sourceSurfaceId.uuidString,
                    "source_surface_ref": v2Ref(
                        kind: .surface,
                        uuid: sourceSurfaceId
                    ),
                    "source_pane_id": sourcePane.id.uuidString,
                    "source_pane_ref": v2Ref(
                        kind: .pane,
                        uuid: sourcePane.id
                    ),
                    "target_pane_id": v2OrNull(
                        targetPaneUUID?.uuidString
                    ),
                    "target_pane_ref": v2Ref(
                        kind: .pane,
                        uuid: targetPaneUUID
                    ),
                    "created_split": placement.createdSplit,
                    "placement_strategy": targetPaneUUID == sourcePane.id
                        ? "same_pane" : placement.createdSplit ? "split_right" : "reuse_right_sibling",
                    "show_omnibar": placement.panel.isOmnibarVisible,
                    "transparent_background": transparentBackground,
                    "bypass_remote_proxy": bypassRemoteProxy,
                ]
            )
            if focus,
               case .dock = container,
               let appDelegate = AppDelegate.shared {
                _ = BrowserActionDispatcher(
                    appDelegate: appDelegate
                ).perform(
                    .focus,
                    on: BrowserActionTarget(
                        host: container.host,
                        panelId: browserPanelId
                    )
                )
            }
            result = .ok(payload)
        }
        return result
    }
}
