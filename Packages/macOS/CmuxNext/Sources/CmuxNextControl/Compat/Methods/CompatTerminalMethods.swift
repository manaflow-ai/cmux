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
        guard surface.isTerminal || surface.isRemoteTerminal else { throw CompatErrors.invalid(ControlStrings.text("control.error.surfaceNotTerminal", "Surface is not a terminal")) }
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
        if surface.isRemoteTerminal {
            // Paste mode needs a surface; the terminal gets the plain text.
            let (connection, resource) = try await remoteTerminal(surface, service: call.service)
            try await CompatDeadline.run("terminal.input.write") { try await connection.writeTerminal(resource, text: text) }
        } else {
            try await call.service.daemon("send", session: surface.sessionID, mutates: false) { try await $0.send(handle, text: text, paste: paste) }
        }
        var result = ids(world, surface, target)
        result["queued"] = false
        return .object(result)
    }

    static func send(_ text: String, to surface: CompatWorld.Surface, service: CompatService) async throws {
        let handle = surface.handle
        try await service.daemon("send", session: surface.sessionID, mutates: false) { try await $0.send(handle, text: text) }
    }

    static func sendKey(_ call: CompatCall) async throws -> JSON {
        guard let raw = call.string("key"), !raw.isEmpty else { throw CompatErrors.invalid(ControlStrings.text("control.error.missingKey", "Missing key")) }
        guard let chord = CompatKeys.chord(raw) else {
            throw ControlError(code: "invalid_params", message: ControlStrings.text("control.error.unknownKey", "Unknown key"), data: ["key": .string(raw)])
        }
        let (world, surface, target) = try await terminal(call)
        let handle = surface.handle
        if surface.isRemoteTerminal {
            let (connection, resource) = try await remoteTerminal(surface, service: call.service)
            try await CompatDeadline.run("terminal.input.keys") { try await connection.sendTerminalKeys(resource, keys: [chord]) }
        } else {
            try await call.service.daemon("send-key", session: surface.sessionID, mutates: false) { try await $0.sendKeys(handle, [chord]) }
        }
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
        var text: String
        if surface.isRemoteTerminal {
            // The viewport only: history of a tab-less terminal comes as
            // styled rows (`terminal.history.read`), not text.
            let (connection, resource) = try await remoteTerminal(surface, service: call.service)
            text = try await CompatDeadline.run("terminal.screen.read") { try await connection.readTerminalScreen(resource).text }
        } else {
            text = try await call.service.daemon("read-screen", session: surface.sessionID, mutates: false) { try await $0.request(CompatReadScreenRequest(surface: handle)).text }
        }
        if scrollback, !surface.isRemoteTerminal {
            let history = try await readHistory(handle, session: surface.sessionID, lastLines: lines, service: call.service)
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

    static func readHistory(_ handle: SurfaceID, session: String?, lastLines: Int?, service: CompatService) async throws -> String {
        let probe = try await service.daemon("read-scrollback", session: session, mutates: false) { try await $0.request(CompatReadScrollbackRequest(surface: handle, start: 0, count: 0)) }
        let total = probe.total
        guard total > 0 else { return "" }
        let wanted = min(total, UInt32(min(lastLines ?? Int(UInt16.max), Int(UInt16.max))))
        let start = total - wanted
        let page = try await service.daemon("read-scrollback", session: session, mutates: false) {
            try await $0.request(CompatReadScrollbackRequest(surface: handle, start: start, count: wanted))
        }
        return page.text
    }

    /// The session and public id of the terminal a remote-terminal tab
    /// shows (data-model.md 1.2b); `set-terminal-keep` names it (the
    /// terminal stays kept, as it already is).
    static func remoteTerminal(_ surface: CompatWorld.Surface, service: CompatService) async throws -> (DaemonConnection, ResourceID) {
        guard let sessionID = surface.tab.remoteSessionID, let terminal = surface.tab.remoteTerminalID else {
            throw CompatErrors.invalid(ControlStrings.text("control.error.surfaceNotTerminal", "Surface is not a terminal"))
        }
        let home = service.router?.snapshots.current.topology.homeSession?.id
        let connection = try service.connection(session: sessionID == home ? nil : sessionID)
        let id = TerminalID(rawValue: terminal)
        guard let resource = try await CompatDeadline.run("set-terminal-keep", { try await connection.keepTerminal(id) }) else {
            throw CompatErrors.unsupported(ControlStrings.text("control.error.remoteTerminalUnnamed", "the terminal's machine runs a cmux-tui that cannot name it; update it"))
        }
        return (connection, resource)
    }

    static func clearHistory(_ call: CompatCall) async throws -> JSON {
        let (world, surface, target) = try await terminal(call)
        if surface.isRemoteTerminal {
            throw CompatErrors.unsupported(ControlStrings.text("control.error.remoteTerminalClearHistory", "clear-history on a terminal of another machine is not supported; clear it on its own session"), method: call.method)
        }
        let handle = surface.handle
        _ = try await call.service.daemon("clear-history", session: surface.sessionID, mutates: false) { try await $0.request(CompatClearHistoryRequest(surface: handle)) }
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
