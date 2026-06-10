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

// MARK: - Browser state and environment subcommands
extension CMUXCLI {
    /// Handles download, cookies, storage, tab, state,
    /// addinitscript/addscript/addstyle, viewport, geolocation/geo, and offline.
    /// Returns true when the subcommand was handled.
    func runBrowserStateSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if subcommand == "download" {
            let sid = try ctx.requireSurface()
            let argsForDownload: [String]
            if ctx.subArgs.first?.lowercased() == "wait" {
                argsForDownload = Array(ctx.subArgs.dropFirst())
            } else {
                argsForDownload = ctx.subArgs
            }

            let (pathOpt, rem1) = parseOption(argsForDownload, name: "--path")
            let (timeoutMsOpt, rem2) = parseOption(rem1, name: "--timeout-ms")
            let (timeoutSecOpt, rem3) = parseOption(rem2, name: "--timeout")

            var params: [String: Any] = ["surface_id": sid]
            if let path = pathOpt ?? ctx.nonFlagArgs(rem3).first {
                params["path"] = path
            }
            if let timeoutMsOpt {
                guard let timeoutMs = Int(timeoutMsOpt) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = timeoutMs
            } else if let timeoutSecOpt {
                guard let seconds = Double(timeoutSecOpt) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let defaultDownloadWaitTimeoutMs = 10_000
            let maxDownloadWaitTimeoutMs = 120_000
            let requestedTimeoutMs = (params["timeout_ms"] as? Int) ?? defaultDownloadWaitTimeoutMs
            let effectiveTimeoutMs = min(requestedTimeoutMs, maxDownloadWaitTimeoutMs)
            let responseTimeout = Double(max(1, effectiveTimeoutMs)) / 1000.0 + 5.0
            let payload = try ctx.client.sendV2(method: "browser.download.wait", params: params, responseTimeout: responseTimeout)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "cookies" {
            let sid = try ctx.requireSurface()
            let cookieVerb = ctx.subArgs.first?.lowercased() ?? "get"
            let cookieArgs = ctx.subArgs.first != nil ? Array(ctx.subArgs.dropFirst()) : []

            let (nameOpt, rem1) = parseOption(cookieArgs, name: "--name")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let (urlOpt, rem3) = parseOption(rem2, name: "--url")
            let (domainOpt, rem4) = parseOption(rem3, name: "--domain")
            let (pathOpt, rem5) = parseOption(rem4, name: "--path")
            let (expiresOpt, _) = parseOption(rem5, name: "--expires")

            var params: [String: Any] = ["surface_id": sid]
            if let nameOpt { params["name"] = nameOpt }
            if let valueOpt { params["value"] = valueOpt }
            if let urlOpt { params["url"] = urlOpt }
            if let domainOpt { params["domain"] = domainOpt }
            if let pathOpt { params["path"] = pathOpt }
            if hasFlag(cookieArgs, name: "--secure") {
                params["secure"] = true
            }
            if hasFlag(cookieArgs, name: "--all") {
                params["all"] = true
            }
            if let expiresOpt {
                guard let expires = Int(expiresOpt) else {
                    throw CLIError(message: "--expires must be an integer Unix timestamp")
                }
                params["expires"] = expires
            }

            switch cookieVerb {
            case "get":
                let payload = try ctx.client.sendV2(method: "browser.cookies.get", params: params)
                ctx.output(payload, fallback: "OK")
            case "set":
                var setParams = params
                let positional = ctx.nonFlagArgs(cookieArgs)
                if setParams["name"] == nil, positional.count >= 1 {
                    setParams["name"] = positional[0]
                }
                if setParams["value"] == nil, positional.count >= 2 {
                    setParams["value"] = positional[1]
                }
                guard setParams["name"] != nil, setParams["value"] != nil else {
                    throw CLIError(message: "browser cookies set requires <name> <value> (or --name/--value)")
                }
                let payload = try ctx.client.sendV2(method: "browser.cookies.set", params: setParams)
                ctx.output(payload, fallback: "OK")
            case "clear":
                let payload = try ctx.client.sendV2(method: "browser.cookies.clear", params: params)
                ctx.output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser cookies subcommand: \(cookieVerb)")
            }
            return true
        }

        if subcommand == "storage" {
            let sid = try ctx.requireSurface()
            let storageArgs = ctx.subArgs
            let storageType = storageArgs.first?.lowercased() ?? "local"
            guard storageType == "local" || storageType == "session" else {
                throw CLIError(message: "browser storage requires type: local|session")
            }
            let op = storageArgs.count >= 2 ? storageArgs[1].lowercased() : "get"
            let rest = storageArgs.count > 2 ? Array(storageArgs.dropFirst(2)) : []
            let positional = ctx.nonFlagArgs(rest)

            var params: [String: Any] = ["surface_id": sid, "type": storageType]
            switch op {
            case "get":
                if let key = positional.first {
                    params["key"] = key
                }
                let payload = try ctx.client.sendV2(method: "browser.storage.get", params: params)
                ctx.output(payload, fallback: "OK")
            case "set":
                guard positional.count >= 2 else {
                    throw CLIError(message: "browser storage \(storageType) set requires <key> <value>")
                }
                params["key"] = positional[0]
                params["value"] = positional[1]
                let payload = try ctx.client.sendV2(method: "browser.storage.set", params: params)
                ctx.output(payload, fallback: "OK")
            case "clear":
                let payload = try ctx.client.sendV2(method: "browser.storage.clear", params: params)
                ctx.output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser storage subcommand: \(op)")
            }
            return true
        }

        if subcommand == "tab" {
            let sid = try ctx.requireSurface()
            let first = ctx.subArgs.first?.lowercased()
            let tabVerb: String
            let tabArgs: [String]
            if let first, ["new", "list", "close", "switch"].contains(first) {
                tabVerb = first
                tabArgs = Array(ctx.subArgs.dropFirst())
            } else if let first, Int(first) != nil {
                tabVerb = "switch"
                tabArgs = ctx.subArgs
            } else {
                tabVerb = "list"
                tabArgs = ctx.subArgs
            }

            switch tabVerb {
            case "list":
                let payload = try ctx.client.sendV2(method: "browser.tab.list", params: ["surface_id": sid])
                ctx.output(payload, fallback: "OK")
            case "new":
                var params: [String: Any] = ["surface_id": sid]
                let url = tabArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    params["url"] = url
                }
                let payload = try ctx.client.sendV2(method: "browser.tab.new", params: params)
                ctx.output(payload, fallback: "OK")
            case "switch", "close":
                let method = (tabVerb == "switch") ? "browser.tab.switch" : "browser.tab.close"
                var params: [String: Any] = ["surface_id": sid]
                let target = tabArgs.first
                if let target {
                    if let index = Int(target) {
                        params["index"] = index
                    } else {
                        params["target_surface_id"] = target
                    }
                }
                let payload = try ctx.client.sendV2(method: method, params: params)
                ctx.output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser tab subcommand: \(tabVerb)")
            }
            return true
        }

        if subcommand == "state" {
            let sid = try ctx.requireSurface()
            guard let stateVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser state requires save|load <path>")
            }
            guard ctx.subArgs.count >= 2 else {
                throw CLIError(message: "browser state \(stateVerb) requires a file path")
            }
            let path = ctx.subArgs[1]
            let method: String
            switch stateVerb {
            case "save":
                method = "browser.state.save"
            case "load":
                method = "browser.state.load"
            default:
                throw CLIError(message: "Unsupported browser state subcommand: \(stateVerb)")
            }
            let payload = try ctx.client.sendV2(method: method, params: ["surface_id": sid, "path": path])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "addinitscript" || subcommand == "addscript" || subcommand == "addstyle" {
            let sid = try ctx.requireSurface()
            let field = (subcommand == "addstyle") ? "css" : "script"
            let flag = (subcommand == "addstyle") ? "--css" : "--script"
            let (scriptOpt, rem1) = parseOption(ctx.subArgs, name: flag)
            let content = (scriptOpt ?? rem1.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires content")
            }
            let payload = try ctx.client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid, field: content])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "viewport" {
            let sid = try ctx.requireSurface()
            guard ctx.subArgs.count >= 2,
                  let width = Int(ctx.subArgs[0]),
                  let height = Int(ctx.subArgs[1]) else {
                throw CLIError(message: "browser viewport requires: <width> <height>")
            }
            let payload = try ctx.client.sendV2(method: "browser.viewport.set", params: ["surface_id": sid, "width": width, "height": height])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "geolocation" || subcommand == "geo" {
            let sid = try ctx.requireSurface()
            guard ctx.subArgs.count >= 2,
                  let latitude = Double(ctx.subArgs[0]),
                  let longitude = Double(ctx.subArgs[1]) else {
                throw CLIError(message: "browser geolocation requires: <latitude> <longitude>")
            }
            let payload = try ctx.client.sendV2(method: "browser.geolocation.set", params: ["surface_id": sid, "latitude": latitude, "longitude": longitude])
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "offline" {
            let sid = try ctx.requireSurface()
            guard let raw = ctx.subArgs.first,
                  let enabled = parseBoolString(raw) else {
                throw CLIError(message: "browser offline requires true|false")
            }
            let payload = try ctx.client.sendV2(method: "browser.offline.set", params: ["surface_id": sid, "enabled": enabled])
            ctx.output(payload, fallback: "OK")
            return true
        }

        return false
    }
}
