public import Foundation

extension SettingsController {
    /// Returns the complete `shortcuts` object for the next keymap export.
    /// The value includes binding, tier and context overrides so an export
    /// can round-trip every keymap concern without touching other settings.
    public func shortcutKeymap() async throws -> JSONValue {
        try await file.value(at: ["shortcuts"]) ?? .object([:])
    }

    /// Imports a keymap object into `shortcuts` in one atomic publish.
    /// Files exported by ``shortcutKeymap()`` contain a top-level
    /// `shortcuts` object; a bare object is accepted as a convenience for
    /// hand-authored keymaps. Existing comments, unknown top-level keys and
    /// settings outside `shortcuts` remain untouched.
    public func importShortcutKeymap(_ value: JSONValue) async throws {
        guard case .object(let root) = value else {
            throw CmuxConfigFile.Failure.invalidPath("keymap must be a JSON object")
        }
        let shortcuts: [String: JSONValue]
        if case .object(let nested)? = root["shortcuts"] {
            shortcuts = nested
        } else if root.keys.contains(where: { ["bindings", "tiers", "when"].contains($0) }) {
            shortcuts = root
        } else {
            shortcuts = ["bindings": .object(root)]
        }
        let edits = shortcuts.map { key, value in
            (path: ["shortcuts", key], value: Optional(value))
        }
        guard !edits.isEmpty else { return }
        try await file.apply(edits)
    }

    /// Writes the `shortcuts` object to `url` as a keymap file
    /// (`{"shortcuts": {...}}`, pretty JSON), atomically.
    public func exportShortcutKeymap(to url: URL) async throws {
        let keymap: JSONValue = .object(["shortcuts": try await shortcutKeymap()])
        try await Self.write(Data(keymap.prettyText().utf8), to: url)
    }

    /// The keymap file's bytes, read off the main actor (a user-chosen file can be on a slow volume).
    @concurrent nonisolated private static func read(_ url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the keymap file atomically, off the main actor.
    @concurrent nonisolated private static func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    /// Reads a keymap file (JSONC) and imports it (``importShortcutKeymap(_:)``),
    /// then reloads so the registry applies it. A file that does not parse
    /// changes nothing.
    public func importShortcutKeymap(from url: URL) async throws {
        let value = try JSONC.parse(try await Self.read(url))
        try await importShortcutKeymap(value)
        await reload()
    }

    /// The edits that switch cmux-next.json to `preset`, from the file as it is.
    public func keymapPlan(_ preset: ShortcutKeymapPreset) async throws -> ShortcutKeymapPlan {
        preset.plan(from: try await shortcutBindings())
    }

    /// Writes `plan` in one publish and returns how to put back every
    /// shortcut it changed (the base keymap toast's Undo).
    public func applyUndoably(_ plan: ShortcutKeymapPlan) async throws -> ShortcutKeymapUndo {
        var previous: [(path: [String], value: JSONValue?)] = []
        for change in plan.changes {
            // Only the paths `apply` writes (the legacy key goes only for a removed override).
            var paths = [["shortcuts", "bindings", change.actionID]]
            if change.write == nil { paths.append(["shortcuts", change.actionID]) }
            for path in paths { previous.append((path, try await file.value(at: path))) }
        }
        try await apply(plan)
        return ShortcutKeymapUndo(edits: previous)
    }

    /// Puts back the shortcuts an ``applyUndoably(_:)`` changed, in one
    /// publish. An edit of the same shortcuts made after the keymap is
    /// overwritten (the toast's Undo lasts seconds).
    public func restore(_ undo: ShortcutKeymapUndo) async throws {
        guard !undo.edits.isEmpty else { return }
        try await file.apply(undo.edits)
    }

    /// Writes `plan` in one publish. A removed override also goes from the
    /// legacy `shortcuts.<id>` form, so the cmux default applies again.
    public func apply(_ plan: ShortcutKeymapPlan) async throws {
        var edits: [(path: [String], value: JSONValue?)] = []
        for change in plan.changes {
            edits.append((["shortcuts", "bindings", change.actionID], change.write))
            if change.write == nil { edits.append((["shortcuts", change.actionID], nil)) }
        }
        try await file.apply(edits)
    }

    /// `shortcuts.bindings` merged over the legacy `shortcuts.<id>` keys, as
    /// `CmuxConfigSnapshot` reads them.
    func shortcutBindings() async throws -> [String: JSONValue] {
        guard case .object(let section)? = try await file.value(at: ["shortcuts"]) else { return [:] }
        var bindings = section.filter { !CmuxConfigSnapshot.reservedShortcutKeys.contains($0.key) }
        if case .object(let entries)? = section["bindings"] {
            bindings.merge(entries) { _, binding in binding }
        }
        return bindings
    }
}

/// The shortcut values a base keymap replaced, as edits that write them back
/// (nil removes a key the keymap added).
public nonisolated struct ShortcutKeymapUndo: Sendable {
    public let edits: [(path: [String], value: JSONValue?)]
}
