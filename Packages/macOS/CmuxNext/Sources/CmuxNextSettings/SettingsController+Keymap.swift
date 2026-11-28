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
        // Rust builds the edits (cmux-config app_ops/keymap.rs `keymap.import_edits`): the key
        // style and keyboard layout (`app.keyStyle`, `app.shortcutLayout`), then each `shortcuts` member.
        guard let reply = try? SettingsRust.call("keymap.import_edits", ["value": value]) else {
            throw CmuxConfigFile.Failure.invalidPath("keymap must be a JSON object")
        }
        let edits = Self.fileEdits(reply)
        guard !edits.isEmpty else { return }
        try await file.apply(edits)
    }

    /// The `{path, value?}` edits of a `keymap.*` reply as file edits (no `value` removes the path).
    nonisolated static func fileEdits(_ reply: JSONValue) -> [(path: [String], value: JSONValue?)] {
        reply["edits"]?.arrayValue?.compactMap { edit in
            edit["path"]?.arrayValue.map { (path: $0.compactMap(\.stringValue), value: edit["value"]) }
        } ?? []
    }

    /// The `app` settings a keymap file carries besides `shortcuts`.
    static let keymapAppPaths = [KeyboardStyleSettings.keyStylePath, KeyboardStyleSettings.shortcutLayoutPath]

    /// The `app` object of a keymap export: the key style and keyboard layout this file sets,
    /// or nil when it sets neither (the defaults).
    func keymapAppSettings() async throws -> JSONValue? {
        var app: [String: JSONValue] = [:]
        for path in Self.keymapAppPaths {
            if let value = try await file.value(at: path) { app[path[1]] = value }
        }
        return app.isEmpty ? nil : .object(app)
    }

    /// Writes the `shortcuts` object to `url` as a keymap file
    /// (`{"shortcuts": {...}}`, pretty JSON), atomically, with `app.keyStyle` and
    /// `app.shortcutLayout` when the settings file sets them, so one file shares a
    /// whole keyboard setup.
    public func exportShortcutKeymap(to url: URL) async throws {
        var object: [String: JSONValue] = ["shortcuts": try await shortcutKeymap()]
        if let app = try await keymapAppSettings() { object["app"] = app }
        try await Self.write(Data(JSONValue.object(object).prettyText().utf8), to: url)
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
        // Only the paths `apply` writes (the legacy key goes only for a removed override).
        for edit in plan.edits { previous.append((edit.path, try await file.value(at: edit.path))) }
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

    /// Writes `plan` in one publish (Rust's edits: a removed override also goes
    /// from the legacy `shortcuts.<id>` form, so the cmux default applies again).
    public func apply(_ plan: ShortcutKeymapPlan) async throws {
        try await file.apply(plan.edits.map { (path: $0.path, value: $0.value) })
    }

    /// `shortcuts.bindings` merged over the legacy `shortcuts.<id>` keys, as
    /// `CmuxConfigSnapshot` reads them (`keymap.bindings`).
    func shortcutBindings() async throws -> [String: JSONValue] {
        let shortcuts = try await file.value(at: ["shortcuts"]) ?? .null
        return SettingsRust.answer("keymap.bindings", ["shortcuts": shortcuts])["bindings"]?.objectValue ?? [:]
    }
}

/// The shortcut values a base keymap replaced, as edits that write them back
/// (nil removes a key the keymap added).
public nonisolated struct ShortcutKeymapUndo: Sendable {
    public let edits: [(path: [String], value: JSONValue?)]
}
