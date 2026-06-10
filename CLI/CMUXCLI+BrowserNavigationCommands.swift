import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Browser navigation subcommands
extension CMUXCLI {
    /// Handles open/open-split/new, goto/navigate, back/forward/reload,
    /// url/get-url, focus-webview, and is-webview-focused.
    /// Returns true when the subcommand was handled.
    func runBrowserNavigationSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if subcommand == "open" || subcommand == "open-split" || subcommand == "new" {
            // Parse routing flags before URL assembly so they never leak into the URL string.
            let (workspaceOpt, argsAfterWorkspace) = parseOption(ctx.subArgs, name: "--workspace")
            let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
            let (focusOpt, urlArgs) = parseOption(argsAfterWindow, name: "--focus")
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let respectExternalOpenRules: Bool = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_RESPECT_EXTERNAL_OPEN_RULES"] else {
                    return false
                }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    return false
                }
            }()

            if ctx.surfaceRaw != nil, subcommand == "open" {
                // Treat `browser <surface> open <url>` as navigate for agent-browser ergonomics.
                let sid = try ctx.requireSurface()
                guard !url.isEmpty else {
                    throw CLIError(message: "browser <surface> open requires a URL")
                }
                let payload = try ctx.client.sendV2(method: "browser.navigate", params: ["surface_id": sid, "url": url])
                ctx.output(payload, fallback: "OK")
                return true
            }

            var params: [String: Any] = [:]
            if !url.isEmpty {
                params["url"] = url
            }
            if let sourceSurface = try normalizeSurfaceHandle(ctx.surfaceRaw, client: ctx.client) {
                params["surface_id"] = sourceSurface
            }
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            if let workspaceRaw {
                if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: ctx.client) {
                    params["workspace_id"] = workspace
                }
            }
            if respectExternalOpenRules {
                params["respect_external_open_rules"] = true
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: ctx.client) {
                    params["window_id"] = window
                }
            }
            try applyFocusOption(focusOpt, defaultValue: false, to: &params)
            let payload = try ctx.client.sendV2(method: "browser.open_split", params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: ctx.effectiveIDFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: ctx.effectiveIDFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            ctx.output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return true
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try ctx.requireSurface()
            var urlArgs = ctx.subArgs
            let snapshotAfter = urlArgs.last == "--snapshot-after"
            if snapshotAfter {
                urlArgs.removeLast()
            }
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if snapshotAfter {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: "browser.navigate", params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "back" || subcommand == "forward" || subcommand == "reload" {
            let sid = try ctx.requireSurface()
            let methodMap: [String: String] = [
                "back": "browser.back",
                "forward": "browser.forward",
                "reload": "browser.reload",
            ]
            var params: [String: Any] = ["surface_id": sid]
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: methodMap[subcommand]!, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "url" || subcommand == "get-url" {
            let sid = try ctx.requireSurface()
            let payload = try ctx.client.sendV2(method: "browser.url.get", params: ["surface_id": sid])
            if ctx.effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
            } else {
                print((payload["url"] as? String) ?? "")
            }
            return true
        }

        if ["focus-webview", "focus_webview"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let payload = try ctx.client.sendV2(method: "browser.focus_webview", params: ["surface_id": sid])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if ["is-webview-focused", "is_webview_focused"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let payload = try ctx.client.sendV2(method: "browser.is_webview_focused", params: ["surface_id": sid])
            if ctx.effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: ctx.effectiveIDFormat)))
            } else {
                print((payload["focused"] as? Bool) == true ? "true" : "false")
            }
            return true
        }

        return false
    }
}
