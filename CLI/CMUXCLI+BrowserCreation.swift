import Foundation

extension CMUXCLI {
    func createBrowserFromCLI(
        subcommand: String,
        url: String,
        surfaceRaw: String?,
        workspaceOpt: String?,
        windowOpt: String?,
        focusOpt: String?,
        profileSelector: String?,
        respectExternalOpenRules: Bool,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var params: [String: Any] = [:]
        if !url.isEmpty {
            params["url"] = url
        }
        if let profileSelector {
            params["profile"] = profileSelector
        }
        // The open wrapper inherits its terminal; explicit browser routes do not.
        let useTerminalPlacement = subcommand == "open" && respectExternalOpenRules
            && surfaceRaw == nil && workspaceOpt == nil && windowOpt == nil && profileSelector == nil
        let placementSurfaceRaw = surfaceRaw
            ?? (useTerminalPlacement ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        if let sourceSurface = try normalizeSurfaceHandle(placementSurfaceRaw, client: client) {
            params["surface_id"] = sourceSurface
            if useTerminalPlacement { params["use_terminal_link_browser_placement"] = true }
        }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if respectExternalOpenRules {
            params["respect_external_open_rules"] = true
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        let payload = try client.sendV2(method: "browser.open_split", params: params)
        let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
        let placement = (payload["placement_strategy"] as? String) == "same_pane" ? "samePane" : ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
        printV2Payload(
            payload, jsonOutput: jsonOutput, idFormat: idFormat,
            fallbackText: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)"
        )
    }
}
