import CmuxNextDaemon
import Foundation

/// Terminal I/O forwarded to cmux-tui: `send`, `send-key`, `read-screen`,
/// `read-scrollback`, `clear-history`.
enum CompatTerminalMethods {
    static let table: [String: CompatHandler] = [
        "surface.send_text": .async(sendText),
        "surface.send_key": .async(sendKey),
        "surface.read_text": .async(readText),
        "surface.clear_history": .async(clearHistory),
        "terminal.paste": .async({ call in try await sendText(call, paste: true) }),
    ]

    static func terminal(_ call: CompatCall) async throws -> (CompatWorld, CompatWorld.Surface, CompatTarget) {
        let world = try await call.world()
        let target = call.target(world)
        let surface = try target.surface()
        guard surface.isTerminal else { throw CompatErrors.invalid(ControlStrings.text("control.error.surfaceNotTerminal", "Surface is not a terminal")) }
        return (world, surface, target)
    }

    static func ids(_ world: CompatWorld, _ surface: CompatWorld.Surface, _ target: CompatTarget) -> [String: JSON] {
        CompatJSON.ids(window: (try? target.window()) ?? nil, workspace: world.workspace(surface.workspaceUUID), surface: surface)
    }

    static func sendText(_ call: CompatCall) async throws -> JSON { try await sendText(call, paste: false) }

    static func sendText(_ call: CompatCall, paste: Bool) async throws -> JSON {
        guard let text = call.params["text"]?.stringValue else { throw CompatErrors.invalid(ControlStrings.text("control.error.missingText", "Missing text")) }
        let (world, surface, target) = try await terminal(call)
        let handle = surface.handle
        try await call.service.daemon("send") { try await $0.send(handle, text: text, paste: paste) }
        var result = ids(world, surface, target)
        result["queued"] = false
        return .object(result)
    }

    static func send(_ text: String, to surface: CompatWorld.Surface, service: CompatService) async throws {
        let handle = surface.handle
        try await service.daemon("send") { try await $0.send(handle, text: text) }
    }

    static func sendKey(_ call: CompatCall) async throws -> JSON {
        guard let raw = call.string("key"), !raw.isEmpty else { throw CompatErrors.invalid(ControlStrings.text("control.error.missingKey", "Missing key")) }
        guard let chord = CompatKeys.chord(raw) else {
            throw ControlError(code: "invalid_params", message: ControlStrings.text("control.error.unknownKey", "Unknown key"), data: ["key": .string(raw)])
        }
        let (world, surface, target) = try await terminal(call)
        let handle = surface.handle
        try await call.service.daemon("send-key") { try await $0.sendKeys(handle, [chord]) }
        var result = ids(world, surface, target)
        result["queued"] = false
        return .object(result)
    }

    /// Viewport text; with `scrollback` (or `lines`, which implies it) the
    /// retained history comes first. `lines` keeps the last N lines.
    static func readText(_ call: CompatCall) async throws -> JSON {
        let lines = call.int("lines")
        if let lines, lines <= 0 { throw CompatErrors.invalid(ControlStrings.text("control.error.linesPositive", "lines must be greater than 0")) }
        let scrollback = lines != nil || call.bool("scrollback") == true
        let (world, surface, target) = try await terminal(call)
        let handle = surface.handle
        var text = try await call.service.daemon("read-screen") { try await $0.request(CompatReadScreenRequest(surface: handle)).text }
        if scrollback {
            let history = try await readHistory(handle, lastLines: lines, service: call.service)
            if !history.isEmpty { text = history + "\n" + text }
        }
        if let lines {
            var rows = text.components(separatedBy: "\n")
            while rows.last?.isEmpty == true { rows.removeLast() }
            text = rows.suffix(lines).joined(separator: "\n")
        }
        var result = ids(world, surface, target)
        result["text"] = .string(text)
        result["base64"] = .string(Data(text.utf8).base64EncodedString())
        return .object(result)
    }

    static func readHistory(_ handle: SurfaceID, lastLines: Int?, service: CompatService) async throws -> String {
        let probe = try await service.daemon("read-scrollback") { try await $0.request(CompatReadScrollbackRequest(surface: handle, start: 0, count: 0)) }
        let total = probe.total
        guard total > 0 else { return "" }
        let wanted = min(total, UInt32(min(lastLines ?? Int(UInt16.max), Int(UInt16.max))))
        let start = total - wanted
        let page = try await service.daemon("read-scrollback") {
            try await $0.request(CompatReadScrollbackRequest(surface: handle, start: start, count: wanted))
        }
        return page.text
    }

    static func clearHistory(_ call: CompatCall) async throws -> JSON {
        let (world, surface, target) = try await terminal(call)
        let handle = surface.handle
        _ = try await call.service.daemon("clear-history") { try await $0.request(CompatClearHistoryRequest(surface: handle)) }
        return .object(ids(world, surface, target))
    }
}

/// Old key names (`enter`, `ctrl-c`, `sigint`, `shift+tab`, …) as cmux-tui
/// `send-key` chords (`enter`, `ctrl+c`, `backtab`).
enum CompatKeys {
    static let aliases: [String: String] = [
        "return": "enter", "enter": "enter", "esc": "escape", "escape": "escape", "tab": "tab",
        "shift+tab": "backtab", "backtab": "backtab", "backspace": "backspace", "delete": "delete", "del": "delete",
        "up": "up", "down": "down", "left": "left", "right": "right", "home": "home", "end": "end",
        "pageup": "pageup", "pagedown": "pagedown", "insert": "insert", "space": " ",
        "sigint": "ctrl+c", "eof": "ctrl+d", "suspend": "ctrl+z",
    ]

    static func chord(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let alias = aliases[key] { return alias }
        let parts = key.split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        let modifiers = parts.dropLast().map { modifier -> String? in
            switch modifier {
            case "ctrl", "control", "c": "ctrl"
            case "alt", "opt", "option", "meta", "m": "alt"
            case "shift", "s": "shift"
            default: nil
            }
        }
        guard !modifiers.contains(nil) else { return nil }
        let base = aliases[last] ?? last
        let valid = base.count == 1 || aliases.values.contains(base) || (base.hasPrefix("f") && Int(base.dropFirst()).map { (1...24).contains($0) } == true)
        guard valid else { return nil }
        if modifiers == ["shift"], base == "tab" { return "backtab" }
        return (modifiers.compactMap { $0 } + [base]).joined(separator: "+")
    }
}
