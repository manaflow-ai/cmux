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
/// A numbered family's row (`⌃1…9`, cx-w7uu): its digit on other modifiers
/// moves all nine keys (cmux.json holds the family by its `1`); any other
/// key rebinds that digit alone, in keybindings.json with its index.
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
        let args = params["args"]?.objectValue ?? [:]
        // An unset family (the page's Remove took its keys) gets all nine keys back on the
        // recorded modifiers, checked as a family.
        if registry.descriptor(for: id)?.shortcutFamily == .digits, keys.count == 1 {
            if movesFamily(id, keys[0], params) { return try await moveFamily(id, to: keys[0].modifiers) }
            // An unset family moves all nine keys to the recorded modifiers: it takes a digit.
            if target == nil, movesUnsetFamily(id, params) {
                throw PageError(code: "cmux.keybindings.refused", message: KeybindingStrings.familyNeedsDigit)
            }
        }
        if registry.descriptor(for: id)?.shortcutFamily == .digits, let target, target.argument != nil {
            try refuseSiblings(id, keys: [keys], except: target)
            return try await setInFile(id, keys: keys, when: params["when"]?.stringValue, args: args, replaces: target)
        }
        // cmux.json keeps the action's own `when` and no arguments: only a key change fits.
        let scope = target?.when?.text ?? WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])?.text
        guard params["when"]?.stringValue == scope, args.isEmpty || target != nil, target?.source != .app,
              !isFromFile(target), keys.count <= 2 else {
            return try await setInFile(id, keys: keys, when: params["when"]?.stringValue, args: args, replaces: target)
        }
        // The action's own default keys: its override goes, and the shipped entry (with the keys
        // it yields to others) is back, sharing its keys with the other defaults by design.
        if restoresDefault(params) {
            registry.removeShortcutOverride(for: id)
            try await write { try await settings.resetShortcut(for: id) }
            return
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
        // A removal in keybindings.json never takes out a cmux.json override; one
        // digit of a numbered family cmux.json holds moves the family over (`split`).
        let inConfig = target.map { $0.source == .user && !isFromFile($0) } ?? false
        if inConfig, target?.argument == nil { throw Self.needsKeybindingsJSON }
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
        if inConfig, let target { return try await split(id, row: target, keys: keys, when: clause?.text) }
        try await daemon {
            // The canonical text: the page lists it, and a later edit names the entry by it.
            try await file.set(command: id, key: KeybindingReports.text(keys), when: clause?.text,
                               args: args.mapValues { AppJSON($0).daemonValue }, replaces: target)
        }
    }

    /// One digit of a numbered family cmux.json holds, rebound: keybindings.json
    /// takes the family's nine keys (that digit's new one, the others as
    /// they are) and cmux.json unbinds the action.
    private func split(_ id: ActionID, row: KeyBinding, keys: [Shortcut], when: String?) async throws {
        let name = registry.descriptor(for: id)?.arguments.first?.name ?? "index"
        let rows = RegistryKeyBindings(registry).table.entries.filter {
            $0.command == id && $0.argument != nil && $0.source == .user && !isFromFile($0)
        }
        try await daemon {
            for entry in rows {
                let edited = entry.argument == row.argument
                try await file.set(command: id, key: KeybindingReports.text(edited ? keys : entry.keys),
                                   when: edited ? when : entry.when?.text,
                                   args: [name: .string(entry.argument ?? "")], replaces: nil)
            }
        }
        registry.setShortcutOverride(nil, for: id)
        try await write { try await settings.setShortcut(nil, for: id) }
    }

    /// A digit of a numbered family on another digit's key would take it
    /// from that digit: the family's other entries are conflicts.
    private func refuseSiblings(_ id: ActionID, keys: [[Shortcut]], except target: KeyBinding?) throws {
        let entries = RegistryKeyBindings(registry).table.entries.filter { $0.command == id && $0 != target }
        guard let taken = keys.first(where: { key in entries.contains { $0.keys == key } }), let first = taken.first else { return }
        throw PageError(code: "cmux.keybindings.conflict",
                        message: ShortcutAssessmentText(registry).conflict(first, owners: [id], canKeepBoth: false))
    }

    /// The entry is keybindings.json's (cmux.json overrides are user entries too).
    private func isFromFile(_ entry: KeyBinding?) -> Bool {
        guard let entry, entry.source == .user else { return false }
        return file.isFromFile(entry)
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

    /// Moves the numbered family `id` to `modifiers` (all nine keys) in cmux.json.
    /// Its own keys again write nothing; its default keys drop the override.
    private func moveFamily(_ id: ActionID, to modifiers: NSEvent.ModifierFlags) async throws {
        let first = Shortcut("1", modifiers: modifiers)
        guard registry.effectiveShortcut(for: id) != first || registry.chordOverrides[id] != nil else { return }
        let environment = ShortcutEditEnvironment(chromeChords: BrowserChordTable.chromeReserved)
        try verdict(registry.assessFamilyModifiers(modifiers, for: id, environment: environment), shortcut: first, for: id)
        // A keybindings.json digit entry on one of the new keys would take it from that digit.
        let files = RegistryKeyBindings(registry).table.entries.filter { $0.command == id && isFromFile($0) }
        try refuseSiblings(id, keys: (1...9).map { [Shortcut(String($0), modifiers: modifiers)] }.filter { key in
            files.contains { $0.keys == key }
        }, except: nil)
        if first == registry.descriptor(for: id)?.defaultShortcut {
            registry.removeShortcutOverride(for: id)
            try await write { try await settings.resetShortcut(for: id) }
        } else {
            registry.setShortcutOverride(first, for: id)
            try await write { try await settings.setShortcut(first, for: id) }
        }
    }

    /// The refusal of `key` for `command` before any write (`cmux.keybindings.conflicts`): the
    /// recorder's rules, as `set` checks them (a key a system action always runs, a key of
    /// another action's numbered family, a key macOS keeps), with the action that holds the key
    /// when there is one. Nil when they may be saved; another action's keys in the same place
    /// are the page's question (Overwrite takes them first), not this.
    func refusal(_ params: [String: JSONValue]) -> (message: String, owner: ActionID?)? {
        guard let id = try? command(params), let keys = KeybindingReports.keys(from: params["key"]?.stringValue ?? ""),
              let first = keys.first else { return nil }
        // An unset numbered family moves to the recorded modifiers on its digits (`set`).
        let target = (try? entry(id, params["replaces"]?.objectValue)) ?? nil
        if registry.descriptor(for: id)?.shortcutFamily == .digits, keys.count == 1, target == nil,
           !movesFamily(id, first, params), movesUnsetFamily(id, params) {
            return (KeybindingStrings.familyNeedsDigit, nil)
        }
        guard case .refused(let refusal) = assessment(first, for: id) else { return nil }
        let owner: ActionID? = switch refusal {
        case .systemAction(let owner), .numberedFamily(let owner): owner
        default: nil
        }
        return (ShortcutAssessmentText(registry).refusal(refusal, shortcut: first, id: id), owner)
    }

    /// The `when` the entry `set` writes would carry, for the conflict check before the write
    /// (`cmux.keybindings.conflicts`): a cmux.json override keeps only the action's own context
    /// (its `requires`, Home's chat scope), not a default's extra conditions (`!codeEditorFocused`,
    /// not a terminal); a keybindings.json entry keeps the text sent. As `set` routes them.
    func savedWhen(_ params: [String: JSONValue]) -> WhenClause? {
        let sent = params["when"]?.stringValue
        // The action's default keys again: the shipped entry's `when`, with what it yields.
        if restoresDefault(params), let id = try? command(params),
           let keys = KeybindingReports.keys(from: params["key"]?.stringValue ?? "") {
            return RegistryKeyBindings(registry).shippedWhen(for: id, keys: keys)
        }
        guard let id = try? command(params), toConfig(id, params) else { return sent.flatMap { try? WhenClause.parse($0) } }
        let requiring = WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])
        if KeyBindingDefaults.homeScoped.contains(id) { return WhenClause.and([requiring, KeyBindingDefaults.onHome].compactMap { $0 }) }
        guard KeyBindingDefaults.homeChatScoped.contains(id) else { return requiring }
        return WhenClause.and([requiring, KeyBindingDefaults.onHomeChats].compactMap { $0 })
    }

    /// `set` would give the action its shipped default keys back: a cmux.json override equal to
    /// the default is the default entry again (`RegistryKeyBindings.source`), so it shares keys
    /// with the other shipped defaults by design (each surface's Cmd-0 Actual Size).
    /// A numbered family back on its default modifiers drops its override (`moveFamily`).
    func restoresDefault(_ params: [String: JSONValue]) -> Bool {
        guard let id = try? command(params), let keys = KeybindingReports.keys(from: params["key"]?.stringValue ?? ""),
              keys.count == 1, let shipped = registry.descriptor(for: id)?.defaultShortcut else { return false }
        if registry.descriptor(for: id)?.shortcutFamily == .digits {
            return movesFamily(id, keys[0], params) && Shortcut("1", modifiers: keys[0].modifiers) == shipped
        }
        return toConfig(id, params) && keys[0] == shipped
    }

    /// The actions `set` refuses to share the keys with (another action's keys in the same place):
    /// Overwrite must take the keys from them everywhere, or the save fails after it took some.
    func sameScopeOwners(_ params: [String: JSONValue]) -> Set<ActionID> {
        guard let id = try? command(params), !restoresDefault(params),
              let keys = KeybindingReports.keys(from: params["key"]?.stringValue ?? ""), let first = keys.first,
              case .conflict(let owners, let canKeepBoth, _, _) = assessment(first, for: id), !canKeepBoth else { return [] }
        // Only the owners with an entry on these keys in the same place: an owner in a narrower
        // context keeps its keys outside the new shortcut's (Overwrite takes them only there).
        let scope = WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])?.text
        let entries = RegistryKeyBindings(registry).table.entries
        let same = owners.filter { owner in entries.contains { $0.command == owner && $0.keys == keys && $0.when?.text == scope } }
        // The recorder's rules found one this cannot name: all of them, so the save cannot fail.
        return Set(same.isEmpty ? owners : same)
    }

    /// An unset numbered family recorded in its own place (no arguments, its own `when`): `set`
    /// moves all nine keys to the recorded modifiers.
    private func movesUnsetFamily(_ id: ActionID, _ params: [String: JSONValue]) -> Bool {
        guard case .some(.none) = registry.shortcutOverrides[id], params["args"]?.objectValue?.isEmpty ?? true else { return false }
        return params["when"]?.stringValue == WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])?.text
    }

    /// `set` moves the numbered family `id` to the key's modifiers (all nine keys): an unset
    /// family, or one of its digits recorded on other modifiers in its own place.
    private func movesFamily(_ id: ActionID, _ key: Shortcut, _ params: [String: JSONValue]) -> Bool {
        guard let target = (try? entry(id, params["replaces"]?.objectValue)) ?? nil else {
            return movesUnsetFamily(id, params) && key.key.count == 1 && "123456789".contains(key.key)
        }
        return key.key == target.argument && target.source != .app && !isFromFile(target)
            && params["when"]?.stringValue == target.when?.text
    }

    /// `set` writes the keys to cmux.json (one key or a two-key chord in the action's own `when`).
    private func toConfig(_ id: ActionID, _ params: [String: JSONValue]) -> Bool {
        let target = (try? entry(id, params["replaces"]?.objectValue)) ?? nil
        let requiring = WhenClause.requiring(registry.descriptor(for: id)?.requires ?? [])
        let keys = KeybindingReports.keys(from: params["key"]?.stringValue ?? "") ?? []
        return params["when"]?.stringValue == (target?.when?.text ?? requiring?.text) && target?.source != .app
            && !isFromFile(target) && keys.count <= 2 && registry.descriptor(for: id)?.shortcutFamily != .digits
    }

    /// The palette recorder's rules (`ActionRegistry.assessShortcut`; one
    /// key of a numbered family, `assessKey`).
    private func assess(_ shortcut: Shortcut, for id: ActionID) throws {
        try verdict(assessment(shortcut, for: id), shortcut: shortcut, for: id)
    }

    private func assessment(_ shortcut: Shortcut, for id: ActionID) -> ShortcutAssessment {
        let environment = ShortcutEditEnvironment(chromeChords: BrowserChordTable.chromeReserved)
        return registry.descriptor(for: id)?.shortcutFamily == nil
            ? registry.assessShortcut(shortcut, for: id, environment: environment)
            : registry.assessKey(shortcut, for: id, environment: environment)
    }

    /// A refusal, or a conflict in the same place, is the page's error.
    private func verdict(_ assessment: ShortcutAssessment, shortcut: Shortcut, for id: ActionID) throws {
        let text = ShortcutAssessmentText(registry)
        switch assessment {
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
