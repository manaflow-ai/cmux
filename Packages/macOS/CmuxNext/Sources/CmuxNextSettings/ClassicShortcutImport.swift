import AppKit
import CmuxNextActions
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
    /// action ID, as next's binding object (`ShortcutBindingFormat`).
    static func recorded(in sources: [UserDefaults]) -> [String: JSONValue] {
        for defaults in sources {
            var found: [String: JSONValue] = [:]
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
                guard let data = value as? Data, let binding = binding(stored: data) else { continue }
                found[String(key.dropFirst(prefix.count))] = binding
            }
            if !found.isEmpty { return found }
        }
        return [:]
    }

    /// Classic's `StoredShortcut` as `{ "first": {...}, "second": {...} }`,
    /// or nil for a key next can't bind (classic's media keys).
    static func binding(stored data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = stroke(object, key: "key", prefix: nil) else { return nil }
        var members: [String: JSONValue] = ["first": first]
        if let chordKey = object["chordKey"] as? String, !chordKey.isEmpty {
            guard let second = stroke(object, key: "chordKey", prefix: "chord") else { return nil }
            members["second"] = second
        }
        let binding = JSONValue.object(members)
        return ShortcutBindingFormat.parse(binding) == nil ? nil : binding
    }

    /// One stroke; `prefix` names the chord's modifier fields (`chordShift`).
    private static func stroke(_ object: [String: Any], key: String, prefix: String?) -> JSONValue? {
        guard let rawKey = object[key] as? String,
              rawKey.count <= 1 || ShortcutBindingFormat.keyEquivalent(forToken: rawKey) != nil else { return nil }
        var stroke: [String: JSONValue] = ["key": .string(rawKey)]
        for modifier in ["command", "shift", "option", "control"] {
            let name = prefix.map { $0 + modifier.prefix(1).uppercased() + modifier.dropFirst() } ?? modifier
            stroke[modifier] = .bool(object[name] as? Bool ?? false)
        }
        return .object(stroke)
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
        let others = ClassicShortcutImport.domains.filter { $0 != bundleIdentifier }.compactMap { UserDefaults(suiteName: $0) }
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
        var edits: [(path: [String], value: JSONValue?)] = []
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
        if !edits.isEmpty {
            try await file.apply(edits)
            await reloadAfterWrite()
        }
        marker.set(true, forKey: ClassicShortcutImport.importedKey)
        return !edits.isEmpty
    }
}
