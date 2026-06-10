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

// MARK: - Browser diagnostics subcommands
extension CMUXCLI {
    /// Handles identify, console, errors, highlight, trace, and network.
    /// Returns true when the subcommand was handled.
    func runBrowserDiagnosticsSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if subcommand == "identify" {
            let surface = try normalizeSurfaceHandle(ctx.surfaceRaw, client: ctx.client, allowFocused: true)
            var payload = try ctx.client.sendV2(method: "system.identify")
            if let surface {
                let urlPayload = try ctx.client.sendV2(method: "browser.url.get", params: ["surface_id": surface])
                let titlePayload = try ctx.client.sendV2(method: "browser.get.title", params: ["surface_id": surface])
                var browser: [String: Any] = [:]
                browser["surface"] = surface
                browser["url"] = urlPayload["url"] ?? ""
                browser["title"] = titlePayload["title"] ?? ""
                payload["browser"] = browser
            }
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "console" {
            let sid = try ctx.requireSurface()
            let consoleVerb = ctx.subArgs.first?.lowercased() ?? "list"
            let method = (consoleVerb == "clear") ? "browser.console.clear" : "browser.console.list"
            if consoleVerb != "list" && consoleVerb != "clear" {
                throw CLIError(message: "Unsupported browser console subcommand: \(consoleVerb)")
            }
            let payload = try ctx.client.sendV2(method: method, params: ["surface_id": sid])
            if ctx.effectiveJSONOutput || consoleVerb == "clear" {
                ctx.output(payload, fallback: "OK")
            } else {
                print(ctx.displayBrowserLogItems(payload["entries"]) ?? "No console entries")
            }
            return true
        }

        if subcommand == "errors" {
            let sid = try ctx.requireSurface()
            let errorsVerb = ctx.subArgs.first?.lowercased() ?? "list"
            var params: [String: Any] = ["surface_id": sid]
            if errorsVerb == "clear" {
                params["clear"] = true
            } else if errorsVerb != "list" {
                throw CLIError(message: "Unsupported browser errors subcommand: \(errorsVerb)")
            }
            let payload = try ctx.client.sendV2(method: "browser.errors.list", params: params)
            if ctx.effectiveJSONOutput || errorsVerb == "clear" {
                ctx.output(payload, fallback: "OK")
            } else {
                print(ctx.displayBrowserLogItems(payload["errors"]) ?? "No browser errors")
            }
            return true
        }

        if subcommand == "highlight" {
            let sid = try ctx.requireSurface()
            let (selectorOpt, rem1) = parseOption(ctx.subArgs, name: "--selector")
            let selector = selectorOpt ?? ctx.nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser highlight requires a selector")
            }
            let payload = try ctx.client.sendV2(method: "browser.highlight", params: ["surface_id": sid, "selector": selector])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "trace" {
            let sid = try ctx.requireSurface()
            guard let traceVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser trace requires start|stop")
            }
            let method: String
            switch traceVerb {
            case "start":
                method = "browser.trace.start"
            case "stop":
                method = "browser.trace.stop"
            default:
                throw CLIError(message: "Unsupported browser trace subcommand: \(traceVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if ctx.subArgs.count >= 2 {
                params["path"] = ctx.subArgs[1]
            }
            let payload = try ctx.client.sendV2(method: method, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "network" {
            let sid = try ctx.requireSurface()
            guard let networkVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser network requires route|unroute|requests")
            }
            let networkArgs = Array(ctx.subArgs.dropFirst())
            switch networkVerb {
            case "route":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network route requires a URL/pattern")
                }
                var params: [String: Any] = ["surface_id": sid, "url": pattern]
                if hasFlag(networkArgs, name: "--abort") {
                    params["abort"] = true
                }
                let (bodyOpt, _) = parseOption(networkArgs, name: "--body")
                if let bodyOpt {
                    params["body"] = bodyOpt
                }
                let payload = try ctx.client.sendV2(method: "browser.network.route", params: params)
                ctx.output(payload, fallback: "OK")
            case "unroute":
                guard let pattern = networkArgs.first else {
                    throw CLIError(message: "browser network unroute requires a URL/pattern")
                }
                let payload = try ctx.client.sendV2(method: "browser.network.unroute", params: ["surface_id": sid, "url": pattern])
                ctx.output(payload, fallback: "OK")
            case "requests":
                let payload = try ctx.client.sendV2(method: "browser.network.requests", params: ["surface_id": sid])
                ctx.output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser network subcommand: \(networkVerb)")
            }
            return true
        }

        return false
    }
}
