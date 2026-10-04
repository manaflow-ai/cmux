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

    /// `keybinding.list`: every entry in precedence order (a later entry
    /// wins), optionally filtered by `query` (title, command id or key text,
    /// case-insensitive), `command` and `source`. Each entry has an `id`
    /// (its position in the table) and `conflicts`: the ids of the other
    /// entries on the same keys whose `when` can hold at the same time.
    static func list(_ params: [String: JSONValue], registry: ActionRegistry) -> JSONValue {
        let query = params["query"]?.stringValue?.lowercased() ?? ""
        let command = params["command"]?.stringValue
        let source = params["source"]?.stringValue
        let entries = RegistryKeyBindings(registry).table.entries
        let byKeys = Dictionary(grouping: entries.indices, by: { entries[$0].keys })
        let rows = entries.indices.filter { index in
            let entry = entries[index]
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
            let conflicts = (byKeys[entry.keys] ?? []).filter { $0 != index && WhenClause.canOverlap(entries[$0].when, entry.when) }
            object["conflicts"] = .array(conflicts.map { JSONValue($0) })
            return .object(object)
        }
        // Defaults a removal took out: listed (never resolved) so the editor can reset them.
        let table = RegistryKeyBindings(registry).table
        let removed = table.removed.enumerated().filter { _, entry in
            (command == nil || registry.canonicalID(for: ActionID(rawValue: command ?? "")) == entry.command)
                && (source == nil || entry.source.name == source)
        }.map { offset, entry -> JSONValue in
            guard case .object(var object) = json(entry, registry: registry) else { return .null }
            object["id"] = JSONValue(entries.count + offset)
            object["removed"] = true
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
