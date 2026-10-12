import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextPages
import CmuxNextSettings

/// `cmux.keybindings.set`, `remove` and `reset` of the Keyboard Shortcuts
/// page, written to cmux.json (`shortcuts.bindings.<id>`, one key or a
/// two-key chord per action) through the settings writer, as the palette's
/// recorder writes. Each change goes to the registry at once (the page
/// re-lists before the file watcher confirms); a failed write reloads the
/// file. The recorder's assessment decides: a refusal, or a conflict with
/// an action in the same place, is an error; a conflict in another place
/// is saved and listed. Ghostty rows are the user's Ghostty config and are
/// never written. What cmux.json cannot hold (a `when` clause, arguments,
/// three or four keys, one of several keys of an action, an app's entry)
/// and every keybindings.json entry is written to keybindings.json by the
/// home daemon (`file`, cx-9ce.17); without it such a change is unsupported.
@MainActor
struct KeybindingPageWrites {
    let registry: ActionRegistry
    let settings: SettingsController
    let file: KeybindingsFileService

    /// `{command, key, when?, args?, replaces?: {key, when}}`.
    func set(_ params: [String: JSONValue]) async throws {
        let id = try command(params)
        let target = try entry(id, params["replaces"]?.objectValue)
        if let target, target.source.isGhostty { throw Self.readOnly }
        let text = params["key"]?.stringValue ?? ""
        guard let keys = KeybindingReports.keys(from: text) else {
            throw PageError(code: "cmux.keybindings.invalid", message: KeybindingStrings.invalidKeys(text))
        }
        // cmux.json keeps the action's own `when` and no arguments: only a key change fits.
        let scope = target?.when?.text ?? WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])?.text
        let args = params["args"]?.objectValue ?? [:]
        guard params["when"]?.stringValue == scope, args.isEmpty || target != nil, target?.source != .app,
              !isFromFile(target), keys.count <= 2 else {
            return try await setInFile(id, keys: keys, when: params["when"]?.stringValue, args: args, replaces: target)
        }
        switch keys.count {
        case 1:
            let shortcut = keys[0]
            try assess(shortcut, for: id)
            registry.setShortcutOverride(shortcut, for: id)
            try await write { try await settings.setShortcut(shortcut, for: id) }
        case 2:
            try assess(keys[0], for: id)
            registry.setChordOverride(ShortcutChord(keys[0], keys[1]), for: id)
            let value = JSONValue.array(keys.map { .string(KeybindingReports.text([$0])) })
            try await write { try await settings.set(value, at: ["shortcuts", "bindings", id.rawValue]) }
        default:
            throw PageError(code: "cmux.keybindings.refused", message: KeybindingStrings.atMostTwoKeys)
        }
    }

    /// `{command, key, when}`: unbinds the action in cmux.json.
    func remove(_ params: [String: JSONValue]) async throws {
        let id = try command(params)
        let target = try entry(id, params)
        if let target, target.source.isGhostty { throw Self.readOnly }
        // cmux.json unbinds the whole action (keybindings.json entries stay): one of
        // several keys, an app's entry or a keybindings.json entry is a keybindings.json edit.
        let others = RegistryKeyBindings(registry).table.entries.filter {
            $0.command == id && !$0.source.isGhostty && $0 != target && !isFromFile($0)
        }
        if let target, target.source == .app || isFromFile(target) || (target.source == .default && !others.isEmpty) {
            guard file.serves else { throw Self.needsKeybindingsJSON }
            return try await daemon { try await file.remove(target) }
        }
        guard others.isEmpty else { throw Self.needsKeybindingsJSON }
        registry.setShortcutOverride(nil, for: id)
        try await write { try await settings.setShortcut(nil, for: id) }
    }

    /// `{command}`: removes the action's cmux.json override and its
    /// keybindings.json entries and removals.
    func reset(_ params: [String: JSONValue]) async throws {
        let id = try command(params)
        registry.removeShortcutOverride(for: id)
        try await write { try await settings.resetShortcut(for: id) }
        let layers = registry.keyBindingLayers
        if file.serves, layers.user.contains(where: { $0.command == id }) || layers.removals.contains(where: { $0.command == id }) {
            try await daemon { try await file.reset(id) }
        }
    }

    /// Writes the binding to keybindings.json, checked against the catalog
    /// and the recorder's rules first (the loader would drop what fails).
    private func setInFile(_ id: ActionID, keys: [Shortcut], when: String?, args: [String: JSONValue],
                           replaces target: KeyBinding?) async throws {
        guard file.serves else {
            throw keys.count > 2 ? PageError(code: "cmux.keybindings.refused", message: KeybindingStrings.atMostTwoKeys) : Self.needsKeybindingsJSON
        }
        // A removal in keybindings.json never takes out a cmux.json override.
        if let target, target.source == .user, !isFromFile(target) { throw Self.needsKeybindingsJSON }
        var clause: WhenClause?
        if let when {
            do { clause = try WhenClause.parse(when) } catch {
                throw PageError(code: "cmux.keybindings.invalid", message: String(describing: error))
            }
        }
        let values = args.compactMapValues { value -> ActionValue? in
            switch value {
            case .string(let text): .string(text)
            case .bool(let flag): .bool(flag)
            case .number(let number): Int(exactly: number).map(ActionValue.int) ?? .string(String(number))
            default: nil
            }
        }
        let entry = KeyBinding(keys: keys, command: id, arguments: values, when: clause, source: .user)
        if case .failure(let kind) = KeyBindingLoader(registry).validated(entry) {
            throw PageError(code: "cmux.keybindings.invalid", message: String(describing: kind))
        }
        try assess(keys[0], for: id)
        try await daemon {
            try await file.set(command: id, key: KeybindingReports.text(keys), when: when,
                               args: args.mapValues { AppJSON($0).daemonValue }, replaces: target)
        }
    }

    /// The entry is keybindings.json's (cmux.json overrides are user entries too).
    private func isFromFile(_ entry: KeyBinding?) -> Bool {
        guard let entry, entry.source == .user else { return false }
        return registry.keyBindingLayers.user.contains(entry)
    }

    /// Writes keybindings.json through the daemon; its refusal is the page's error.
    private func daemon(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as PageError {
            throw error
        } catch {
            throw PageError(code: "cmux.keybindings.write_failed", message: String(describing: error))
        }
    }

    // MARK: Steps

    private func command(_ params: [String: JSONValue]) throws -> ActionID {
        let raw = params["command"]?.stringValue ?? ""
        let id = registry.canonicalID(for: ActionID(rawValue: raw))
        guard registry.descriptor(for: id) != nil || registry.action(for: id) != nil else {
            throw PageError(code: "cmux.keybindings.invalid", message: KeybindingStrings.unknownCommand(raw))
        }
        return id
    }

    /// The table entry of `id` with the keys and `when` text of `ref`, or nil
    /// for a new entry.
    private func entry(_ id: ActionID, _ ref: [String: JSONValue]?) throws -> KeyBinding? {
        guard let ref, let text = ref["key"]?.stringValue, let keys = KeybindingReports.keys(from: text) else { return nil }
        let when = ref["when"]?.stringValue
        return RegistryKeyBindings(registry).table.entries.last { $0.command == id && $0.keys == keys && $0.when?.text == when }
    }

    /// The palette recorder's rules (`ActionRegistry.assessShortcut`).
    private func assess(_ shortcut: Shortcut, for id: ActionID) throws {
        let text = ShortcutAssessmentText(registry)
        let environment = ShortcutEditEnvironment(chromeChords: BrowserChordTable.chromeReserved)
        switch registry.assessShortcut(shortcut, for: id, environment: environment) {
        case .available:
            return
        case .refused(let refusal):
            throw PageError(code: "cmux.keybindings.refused", message: text.refusal(refusal, shortcut: shortcut, id: id))
        case .conflict(let owners, let canKeepBoth, _, _):
            guard canKeepBoth else {
                throw PageError(code: "cmux.keybindings.conflict", message: text.conflict(shortcut, owners: owners, canKeepBoth: false))
            }
        }
    }

    /// Writes cmux.json; a failed write reloads the file, so the registry
    /// change never outlives it.
    private func write(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await settings.reload()
            throw PageError(code: "cmux.keybindings.write_failed", message: String(describing: error))
        }
    }

    private static var readOnly: PageError {
        PageError(code: "cmux.keybindings.read_only", message: KeybindingStrings.ghosttyReadOnly)
    }

    private static var needsKeybindingsJSON: PageError {
        PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.needsKeybindingsJSON)
    }
}
