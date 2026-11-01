import AppKit
import CmuxNextActions
import CmuxNextSettings

/// The read ops of the binding table (R59, catalog ops `keybinding.list`,
/// `keybinding.resolve`, `context.keys`) as JSON, pure over a registry and a
/// window's context keys so tests and every surface share them. Keys are in
/// keybindings.json syntax (`ctrl+k s`: strokes separated by spaces).
enum KeybindingReports {
    /// `ctrl+k s` -> keys; nil when a stroke does not parse.
    static func keys(from text: String) -> [Shortcut]? {
        let strokes = text.split(separator: " ").map { ShortcutBindingFormat.parseStroke(String($0)) }
        guard !strokes.isEmpty, !strokes.contains(where: { $0 == nil }) else { return nil }
        return strokes.compactMap { $0 }.map(SettingsApplier.shortcut(for:))
    }

    /// Keys -> `ctrl+k s`.
    static func text(_ keys: [Shortcut]) -> String {
        keys.map { key in
            ShortcutBindingFormat.configString(ShortcutStrokeSpec(
                key: key.key, command: key.modifiers.contains(.command), shift: key.modifiers.contains(.shift),
                option: key.modifiers.contains(.option), control: key.modifiers.contains(.control)))
        }.joined(separator: " ")
    }

    static func json(_ value: ActionValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): JSONValue(number)
        case .bool(let flag): .bool(flag)
        case .target(let ref): .string("\(ref.kind.rawValue):\(ref.id)")
        }
    }

    static func json(_ value: KeyContextValue) -> JSONValue {
        switch value {
        case .bool(let flag): .bool(flag)
        case .string(let text): .string(text)
        case .number(let number): .number(number)
        case .strings(let list): .array(list.map(JSONValue.string))
        }
    }

    /// One entry: keys, display, command, title, `when` text, args, source.
    static func json(_ binding: KeyBinding, registry: ActionRegistry) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(text(binding.keys)),
            "display": .string(binding.keys.map(\.displayString).joined(separator: " ")),
            "command": .string(binding.command.rawValue),
            "title": .string(registry.title(for: binding.command) ?? binding.command.rawValue),
            "when": binding.when.map { .string($0.text) } ?? .null,
            "source": .string(binding.source.name),
        ]
        var args = binding.arguments.mapValues(json)
        if let argument = binding.argument {
            args[registry.descriptor(for: binding.command)?.arguments.first?.name ?? "value"] = .string(argument)
        }
        if !args.isEmpty { object["args"] = .object(args) }
        return .object(object)
    }

    /// The Keyboard Shortcuts page's list (`cmux.keybindings.list`): every
    /// entry, but a user Ghostty keybind once. Its app-wide
    /// `.ghosttyFallback` entry (same keys and command as its `.ghostty`
    /// entry) is not a second row, so the remaining `ghostty-fallback` rows
    /// are Ghostty's defaults. A binding the table holds twice is one row,
    /// its later entry (the one that runs): two rows with one identity piled
    /// up on the page (dogfood run 7).
    /// A row of an action in `heldElsewhere` (a
    /// system-wide key `GlobalHotKeyService` could not register: another app
    /// holds it) carries `heldElsewhere: true`. An action cmux.json unbinds
    /// (the page's Remove on its only key) is one `unset` row with no keys, so
    /// it stays listed and can get a key again.
    static func pageList(_ params: [String: JSONValue], registry: ActionRegistry,
                         heldElsewhere: Set<ActionID> = []) -> JSONValue {
        let table = RegistryKeyBindings(registry).table
        let entries = table.entries
        let user = Set(entries.filter { $0.source == .ghostty }.map { GhosttyRow(keys: $0.keys, command: $0.command) })
        var later: Set<KeyBinding> = []
        let repeated = Set(entries.indices.reversed().filter { !later.insert(entries[$0]).inserted })
        var page = list(params, registry: registry) { index in
            let entry = entries[index]
            return !repeated.contains(index)
                && (entry.source != .ghosttyFallback || !user.contains(GhosttyRow(keys: entry.keys, command: entry.command)))
        }
        if case .object(var object) = page, case .array(let rows)? = object["bindings"] {
            let firstID = entries.count + table.removed.count + table.claimedByGhostty.count
            object["bindings"] = .array(rows + unsetRows(params, registry: registry, bound: Set(entries.map(\.command)), firstID: firstID))
            page = .object(object)
        }
        guard !heldElsewhere.isEmpty, case .object(var object) = page, case .array(let rows)? = object["bindings"] else { return page }
        object["bindings"] = .array(rows.map { row in
            guard case .object(var entry) = row, entry["removed"] == nil,
                  let command = entry["command"]?.stringValue, heldElsewhere.contains(ActionID(rawValue: command)) else { return row }
            entry["heldElsewhere"] = true
            return .object(entry)
        })
        return .object(object)
    }

    /// `cmux.keybindings.conflicts` `{command, key, when?}`: the other
    /// actions' entries new keys for `command` would share a context with,
    /// before they are saved: where both hold, one takes the key from the
    /// other (a browser-only Cmd-T takes New Tab's in the browser).
    /// `when` is the condition the write would carry (`KeybindingPageWrites.savedWhen`).
    /// Each row's `takesAll`: the new keys' `when` holds wherever that entry runs
    /// (`WhenClause.implies`), so Overwrite removes its keys; else the entry keeps them outside
    /// the new keys' context; `sameScope` (`KeybindingPageWrites.sameScopeOwners`) always loses
    /// them. `asDefault`: the keys are the action's shipped default again
    /// (`KeybindingPageWrites.restoresDefault`); as in ``list``, two shipped defaults never conflict.
    static func conflicts(_ params: [String: JSONValue], when: WhenClause?, asDefault: Bool = false,
                          sameScope: Set<ActionID> = [], registry: ActionRegistry) -> JSONValue {
        let command = registry.canonicalID(for: ActionID(rawValue: params["command"]?.stringValue ?? ""))
        guard let keys = keys(from: params["key"]?.stringValue ?? "") else { return ["bindings": []] }
        let entries = RegistryKeyBindings(registry).table.entries
        // A binding the table holds twice (the Chrome tab keys) is one row, as on the page.
        var seen: Set<KeyBinding> = []
        let rows = entries.indices.filter { index in
            let entry = entries[index]
            // The user's Ghostty config is read-only here, and in a terminal cmux's action runs
            // first (`ShortcutNote.ghosttyKeybind`): never one to take keys from.
            guard entry.keys == keys, entry.command != command, !entry.source.isGhostty else { return false }
            if asDefault, entry.source == .default { return false }
            return WhenClause.canOverlap(entry.when, when) && seen.insert(entry).inserted
        }.map { index -> JSONValue in
            guard case .object(var object) = json(entries[index], registry: registry) else { return .null }
            object["id"] = JSONValue(index)
            object["conflicts"] = []
            // The new keys hold wherever this entry runs: Overwrite takes them from it. Else they
            // only win where their own `when` holds, and the entry keeps them everywhere else.
            // An action the write refuses to share the keys with (`sameScope`) always loses them.
            // A restored default sits under every user entry: one that can overlap it must go, or it
            // keeps the keys where both hold.
            object["takesAll"] = .bool(asDefault || sameScope.contains(entries[index].command)
                || WhenClause.implies(entries[index].when, when))
            return .object(object)
        }
        return ["bindings": .array(rows)]
    }

    /// Rows of the actions cmux.json unbinds (`shortcuts.bindings.<id>: null`)
    /// that have no other entry: no keys, the action's own `when`, source `user`
    /// (Reset gives the default back).
    private static func unsetRows(_ params: [String: JSONValue], registry: ActionRegistry,
                                  bound: Set<ActionID>, firstID: Int) -> [JSONValue] {
        let command = params["command"]?.stringValue.map { registry.canonicalID(for: ActionID(rawValue: $0)) }
        let ids = registry.shortcutOverrides.compactMap { id, shortcut in shortcut == nil ? id : nil }
            .filter { !bound.contains($0) && registry.disabledFeature(for: $0) == nil && (command == nil || command == $0) }
            .sorted { $0.rawValue < $1.rawValue }
        return ids.enumerated().map { offset, id in
            let when = WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])
            return .object([
                "id": JSONValue(firstID + offset),
                "key": "",
                "display": "",
                "command": .string(id.rawValue),
                "title": .string(registry.title(for: id) ?? id.rawValue),
                "when": when.map { .string($0.text) } ?? .null,
                "source": .string(KeyBinding.Source.user.name),
                "unset": true,
                "conflicts": [],
            ])
        }
    }

    private struct GhosttyRow: Hashable {
        var keys: [Shortcut]
        var command: ActionID
    }

    /// `keybinding.list`: every entry in precedence order (a later entry
    /// wins), optionally filtered by `query` (title, command id or key text,
    /// case-insensitive), `command` and `source`. Each entry has an `id`
    /// (its position in the table) and `conflicts`: the ids of the other
    /// actions' entries on the same keys whose `when` can hold at the same
    /// time (where both hold, the later one takes the key), one of them made
    /// by someone (a user, app or Ghostty config entry: shipped defaults share
    /// keys by design). Bindings in contexts that exclude each other (a
    /// focused browser, a focused terminal) never conflict.
    /// `shows` leaves entries out by their position (``pageList(_:registry:)``).
    static func list(_ params: [String: JSONValue], registry: ActionRegistry, shows: (Int) -> Bool = { _ in true }) -> JSONValue {
        let query = params["query"]?.stringValue?.lowercased() ?? ""
        let command = params["command"]?.stringValue
        let source = params["source"]?.stringValue
        let entries = RegistryKeyBindings(registry).table.entries
        let byKeys = Dictionary(grouping: entries.indices, by: { entries[$0].keys })
        let rows = entries.indices.filter { index in
            let entry = entries[index]
            if !shows(index) { return false }
            if let command, registry.canonicalID(for: ActionID(rawValue: command)) != entry.command { return false }
            if let source, entry.source.name != source { return false }
            guard !query.isEmpty else { return true }
            let title = registry.title(for: entry.command) ?? ""
            return [title, entry.command.rawValue, text(entry.keys), entry.keys.map(\.displayString).joined(separator: " ")]
                .contains { $0.lowercased().contains(query) }
        }.map { index -> JSONValue in
            let entry = entries[index]
            guard case .object(var object) = json(entry, registry: registry) else { return .null }
            object["id"] = JSONValue(index)
            let conflicts = (byKeys[entry.keys] ?? []).filter { other in
                // One action on the keys twice (its cmux and its Ghostty default) runs either way.
                guard other != index, shows(other), entries[other].command != entry.command else { return false }
                // Two shipped defaults share keys by design (the Chrome tab keys, Home's chat keys,
                // the palette's): the app also passes over a winner that cannot run where the key
                // goes. A conflict has a binding someone made (the user's, an app's, Ghostty's config).
                let shipped: [KeyBinding.Source] = [.default, .ghosttyFallback]
                if shipped.contains(entry.source), shipped.contains(entries[other].source) { return false }
                // Both can hold at once: where they do, the later one takes the key from the other.
                return WhenClause.canOverlap(entries[other].when, entry.when)
            }
            object["conflicts"] = .array(conflicts.map { JSONValue($0) })
            return .object(object)
        }
        // Defaults a removal took out: listed (never resolved) so the editor can reset them.
        // Defaults on keys the user's Ghostty config claims: listed with `removedBy: ghostty`
        // (read-only; the Ghostty config, not cmux, gives them back).
        let table = RegistryKeyBindings(registry).table
        let hidden = table.removed.map { ($0, false) } + table.claimedByGhostty.map { ($0, true) }
        let removed = hidden.enumerated().filter { _, item in
            (command == nil || registry.canonicalID(for: ActionID(rawValue: command ?? "")) == item.0.command)
                && (source == nil || item.0.source.name == source)
        }.map { offset, item -> JSONValue in
            guard case .object(var object) = json(item.0, registry: registry) else { return .null }
            object["id"] = JSONValue(entries.count + offset)
            object["removed"] = true
            if item.1 { object["removedBy"] = "ghostty" }
            object["conflicts"] = []
            return .object(object)
        }
        return .object(["bindings": .array(rows + removed)])
    }

    /// `context.keys`: the live context keys of a window.
    static func contextKeys(_ context: KeyContext, window: String?) -> JSONValue {
        .object(["window": window.map(JSONValue.string) ?? .null, "keys": .object(context.values.mapValues(json))])
    }

    /// `keybinding.resolve`: what `keys` does in `context`: the outcome
    /// (`run` with the entry, `armed`, `none`) and every entry for exactly
    /// these keys with its verdict (won, whenFalse, notRunnable, shadowed),
    /// latest first. Nil when `keys` does not parse.
    static func resolve(_ keys: String, context: KeyContext, registry: ActionRegistry, window: String?) -> JSONValue? {
        guard let parsed = Self.keys(from: keys) else { return nil }
        let bindings = RegistryKeyBindings(registry)
        let runnable = { (id: ActionID) in bindings.canPerform(id, in: context.bits) }
        let table = bindings.table
        var object: [String: JSONValue] = ["key": .string(text(parsed)), "window": window.map(JSONValue.string) ?? .null]
        switch table.outcome(of: parsed.map { [$0] }, in: context, isRunnable: runnable) {
        case .run(let binding):
            object["outcome"] = "run"
            object["winner"] = json(binding, registry: registry)
        case .armed(let armed):
            object["outcome"] = "armed"
            object["armed"] = .string(text(armed))
        case .none:
            object["outcome"] = "none"
        }
        object["candidates"] = .array(table.resolve(parsed, in: context, isRunnable: runnable).candidates.map { candidate in
            guard case .object(var entry) = json(candidate.binding, registry: registry) else { return .null }
            entry["verdict"] = .string(candidate.verdict.rawValue)
            return .object(entry)
        })
        object["context"] = .object(context.values.mapValues(json))
        return .object(object)
    }
}
