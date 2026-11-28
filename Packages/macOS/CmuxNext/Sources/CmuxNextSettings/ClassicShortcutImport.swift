import AppKit
import CmuxNextActions
import CmuxNextCompat
public import Foundation

/// Shortcuts a person recorded in classic cmux's Settings. Classic kept them
/// in its own preferences (`shortcut.<action id>`, a JSON-encoded
/// `StoredShortcut`), not in `cmux.json`, so adopting the file alone loses
/// them on the update (hq#1870 parity audit, cx-x5bdq).
enum ClassicShortcutImport {
    /// Classic's preference domains, the stable app first. Next ships under
    /// the same bundle identifiers, so its own channel's are its own defaults.
    static let domains = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc",
                                 "com.cmuxterm.app.staging"]
    /// Set in next's preferences once the import ran, so a shortcut reset in
    /// next stays reset.
    static let importedKey = "classicShortcutsImported"
    static let prefix = "shortcut."

    /// The shortcuts recorded in the first source that has any, by classic
    /// action ID, as next's binding object (`ShortcutBindingFormat`). Rust reads
    /// them (cmux-config app_ops/keymap.rs `keymap.classic_bindings`).
    static func recorded(in sources: [UserDefaults]) -> [String: JSONValue] {
        let entries = sources.map { defaults in
            JSONValue.object(defaults.dictionaryRepresentation().reduce(into: [:]) { out, entry in
                guard entry.key.hasPrefix(prefix), let data = entry.value as? Data,
                      let text = String(data: data, encoding: .utf8) else { return }
                out[entry.key] = .string(text)
            })
        }
        return SettingsRust.answer("keymap.classic_bindings", ["sources": .array(entries)])["bindings"]?.objectValue ?? [:]
    }

    /// Classic's `StoredShortcut` as `{ "first": {...}, "second": {...} }`,
    /// or nil for a key next can't bind (classic's media keys)
    /// (`keymap.classic_binding`).
    static func binding(stored data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let binding = SettingsRust.answer("keymap.classic_binding", ["text": .string(text)])["binding"]
        return binding == .null ? nil : binding
    }

    /// Whether next can use `binding` for `id` without losing a key: it starts
    /// with Command or Control, the keys next routes (a bare key only where
    /// the action's own default is bare, like the diff viewer's), and as one
    /// stroke it is neither the Cmd-J leader nor another action's shortcut in
    /// the same context (classic may have stored its own default for a key
    /// next gives to something else).
    @MainActor static func usable(_ binding: ShortcutBinding, for id: ActionID, in registry: ActionRegistry) -> Bool {
        let first: ShortcutStrokeSpec
        switch binding {
        case .unbound: return true
        case .alternates(let keys):
            return keys.allSatisfy { usable($0, for: id, in: registry) }
        case .chord(let stroke, _):
            return stroke.command || stroke.control
        case .stroke(let stroke): first = stroke
        }
        let descriptor = registry.descriptor(for: id)
        if !first.command, !first.control,
           descriptor?.defaultShortcut?.modifiers.isDisjoint(with: [.command, .control]) != true {
            return false
        }
        let shortcut = SettingsApplier.shortcut(for: first)
        guard shortcut != LeaderLayer.prefix else { return false }
        return !registry.entries.contains { entry in
            entry.descriptor.id != id && entry.descriptor.requires == descriptor?.requires
                && registry.effectiveShortcut(for: entry.descriptor.id) == shortcut
        }
    }
}

extension SettingsController {
    /// `importClassicShortcuts(from:marker:)` from classic's preferences:
    /// this channel's own (`marker`, the app's defaults) first, then the others.
    @discardableResult
    public func importClassicShortcuts(marker: UserDefaults, bundleIdentifier: String? = Bundle.main.bundleIdentifier)
        async throws -> Bool {
        guard !marker.bool(forKey: ClassicShortcutImport.importedKey) else { return false }
        // A DEV build never derives its settings from another build's preferences (BuildStatePaths): its own only.
        let others = BuildIdentity(bundleID: bundleIdentifier, bundledTag: nil).isolatesSharedState ? []
            : ClassicShortcutImport.domains.filter { $0 != bundleIdentifier }.compactMap { UserDefaults(suiteName: $0) }
        return try await importClassicShortcuts(from: [marker] + others, marker: marker)
    }

    /// Writes each shortcut recorded in classic's Settings (`sources`, one
    /// per `ClassicShortcutImport.domains`) to `shortcuts.bindings`
    /// under next's ID, once (`marker` records it). A binding `cmux.json`
    /// already has wins, and an action next doesn't have is skipped.
    /// Returns whether it wrote.
    @discardableResult
    public func importClassicShortcuts(from sources: [UserDefaults], marker: UserDefaults) async throws -> Bool {
        guard !marker.bool(forKey: ClassicShortcutImport.importedKey) else { return false }
        let registry = applier.registry
        var edits: [(path: [String], value: JSONValue)] = []
        for (classicID, binding) in ClassicShortcutImport.recorded(in: sources).sorted(by: { $0.key < $1.key }) {
            let id = registry.canonicalID(for: ActionID(rawValue: classicID)).rawValue
            guard registry.descriptor(for: ActionID(rawValue: id)) != nil,
                  let parsed = ShortcutBindingFormat.parse(binding),
                  ClassicShortcutImport.usable(parsed, for: ActionID(rawValue: id), in: registry) else { continue }
            var bound = false
            for key in Set([id, classicID]) {
                if try await file.value(at: ["shortcuts", "bindings", key]) != nil { bound = true }
                if try await file.value(at: ["shortcuts", key]) != nil { bound = true }
            }
            if !bound { edits.append((["shortcuts", "bindings", id], binding)) }
        }
        let applied = edits.isEmpty ? [] : try await file.setUnset(edits)
        if !applied.isEmpty { await reloadAfterWrite() }
        marker.set(true, forKey: ClassicShortcutImport.importedKey)
        return !applied.isEmpty
    }
}
