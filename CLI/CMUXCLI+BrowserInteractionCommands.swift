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

// MARK: - Browser page interaction subcommands
extension CMUXCLI {
    /// Handles click/dblclick/hover/focus/check/uncheck/scroll-into-view,
    /// type/fill, press/key/keydown/keyup, select, scroll, dialog,
    /// input, and input_mouse/input_keyboard/input_touch.
    /// Returns true when the subcommand was handled.
    func runBrowserInteractionSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if ["click", "dblclick", "hover", "focus", "check", "uncheck", "scrollintoview", "scrollinto", "scroll-into-view"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let (selectorOpt, rem1) = parseOption(ctx.subArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }
            let methodMap: [String: String] = [
                "click": "browser.click",
                "dblclick": "browser.dblclick",
                "hover": "browser.hover",
                "focus": "browser.focus",
                "check": "browser.check",
                "uncheck": "browser.uncheck",
                "scrollintoview": "browser.scroll_into_view",
                "scrollinto": "browser.scroll_into_view",
                "scroll-into-view": "browser.scroll_into_view",
            ]
            var params: [String: Any] = ["surface_id": sid, "selector": selector]
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: methodMap[subcommand]!, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if ["type", "fill"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let (selectorOpt, rem1) = parseOption(ctx.subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }

            let positional = selectorOpt != nil ? rem2 : Array(rem2.dropFirst())
            let hasExplicitText = textOpt != nil || !positional.isEmpty
            let text: String
            if let textOpt {
                text = textOpt
            } else {
                text = positional.joined(separator: " ")
            }
            if subcommand == "type" {
                guard hasExplicitText, !text.isEmpty else {
                    throw CLIError(message: "browser type requires text")
                }
            }

            let method = (subcommand == "type") ? "browser.type" : "browser.fill"
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "text": text]
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: method, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if ["press", "key", "keydown", "keyup"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let (keyOpt, rem1) = parseOption(ctx.subArgs, name: "--key")
            let key = keyOpt ?? rem1.first
            guard let key else {
                throw CLIError(message: "browser \(subcommand) requires a key")
            }
            let methodMap: [String: String] = [
                "press": "browser.press",
                "key": "browser.press",
                "keydown": "browser.keydown",
                "keyup": "browser.keyup",
            ]
            var params: [String: Any] = ["surface_id": sid, "key": key]
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: methodMap[subcommand]!, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "select" {
            let sid = try ctx.requireSurface()
            let (selectorOpt, rem1) = parseOption(ctx.subArgs, name: "--selector")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser select requires a selector")
            }
            let value = valueOpt ?? (selectorOpt != nil ? rem2.first : rem2.dropFirst().first)
            guard let value else {
                throw CLIError(message: "browser select requires a value")
            }
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "value": value]
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try ctx.client.sendV2(method: "browser.select", params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "scroll" {
            let sid = try ctx.requireSurface()
            let (selectorOpt, rem1) = parseOption(ctx.subArgs, name: "--selector")
            let (dxOpt, rem2) = parseOption(rem1, name: "--dx")
            let (dyOpt, rem3) = parseOption(rem2, name: "--dy")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }

            if let dxOpt {
                guard let dx = Int(dxOpt) else {
                    throw CLIError(message: "--dx must be an integer")
                }
                params["dx"] = dx
            }
            if let dyOpt {
                guard let dy = Int(dyOpt) else {
                    throw CLIError(message: "--dy must be an integer")
                }
                params["dy"] = dy
            } else if let first = rem3.first, let dy = Int(first) {
                params["dy"] = dy
            }
            if hasFlag(ctx.subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }

            let payload = try ctx.client.sendV2(method: "browser.scroll", params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if subcommand == "dialog" {
            let sid = try ctx.requireSurface()
            guard let dialogVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser dialog requires <accept|dismiss> [text]")
            }
            let remainder = Array(ctx.subArgs.dropFirst())
            switch dialogVerb {
            case "accept":
                let text = remainder.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var params: [String: Any] = ["surface_id": sid]
                if !text.isEmpty {
                    params["text"] = text
                }
                let payload = try ctx.client.sendV2(method: "browser.dialog.accept", params: params)
                ctx.output(payload, fallback: "OK")
            case "dismiss":
                let payload = try ctx.client.sendV2(method: "browser.dialog.dismiss", params: ["surface_id": sid])
                ctx.output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser dialog subcommand: \(dialogVerb)")
            }
            return true
        }

        if subcommand == "input" {
            let sid = try ctx.requireSurface()
            guard let inputVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser input requires mouse|keyboard|touch")
            }
            let remainder = Array(ctx.subArgs.dropFirst())
            let method: String
            switch inputVerb {
            case "mouse":
                method = "browser.input_mouse"
            case "keyboard":
                method = "browser.input_keyboard"
            case "touch":
                method = "browser.input_touch"
            default:
                throw CLIError(message: "Unsupported browser input subcommand: \(inputVerb)")
            }
            var params: [String: Any] = ["surface_id": sid]
            if !remainder.isEmpty {
                params["args"] = remainder
            }
            let payload = try ctx.client.sendV2(method: method, params: params)
            ctx.output(payload, fallback: "OK")
            return true
        }

        if ["input_mouse", "input_keyboard", "input_touch"].contains(subcommand) {
            let sid = try ctx.requireSurface()
            let payload = try ctx.client.sendV2(method: "browser.\(subcommand)", params: ["surface_id": sid])
            ctx.output(payload, fallback: "OK")
            return true
        }

        return false
    }
}
