import Foundation

/// One shortcut a keymap preset changes.
public struct ShortcutKeymapChange: Sendable, Equatable {
    /// The action whose binding changes.
    public let action: ShortcutAction
    /// The effective binding before the change. ``StoredShortcut/unbound`` when none.
    public let before: StoredShortcut
    /// The effective binding after the change. ``StoredShortcut/unbound`` when none.
    public let after: StoredShortcut
    /// The value written to `shortcuts.bindings`, or `nil` when the change
    /// removes an override so the cmux default applies again.
    public let write: ShortcutKeymapBinding?
    /// macOS shortcuts that claim ``after`` before cmux sees it.
    public let systemConflicts: [MacOSSystemShortcut]
}

/// The `shortcuts.bindings` edits that switch the file to a keymap preset.
///
/// A preset only replaces overrides that are absent or that another preset
/// wrote. A binding the user set by hand, in `cmux.json` or as a legacy
/// UserDefaults shortcut, stays and is listed in ``kept``.
///
/// Ownership is inferred from values, not recorded: nothing marks which
/// preset wrote a binding. A binding typed by hand that equals some preset's
/// value for that action therefore counts as preset-owned, and switching to
/// another preset (including cmux) replaces or removes it.
public struct ShortcutKeymapPlan: Sendable, Equatable {
    /// The preset this plan switches to.
    public let preset: ShortcutKeymapPreset
    /// Every binding that changes, in ``ShortcutAction`` declaration order.
    public let changes: [ShortcutKeymapChange]
    /// Actions the preset would change but the user customized, left alone.
    public let kept: [ShortcutAction]

    /// True when applying the plan would not touch the file.
    public var isEmpty: Bool { changes.isEmpty }

    /// Changes whose new binding collides with a macOS shortcut.
    public var systemConflicts: [ShortcutKeymapChange] {
        changes.filter { !$0.systemConflicts.isEmpty }
    }
}

extension ShortcutKeymapPreset {
    /// Computes the edits that switch `snapshot` to this preset.
    ///
    /// - Parameters:
    ///   - snapshot: The current `shortcuts.bindings` contents of `cmux.json`.
    ///   - legacyBindings: Shortcuts saved in UserDefaults by older Settings
    ///     builds, keyed by action id. They apply when `cmux.json` doesn't
    ///     manage the action and count as set by hand.
    ///   - defaultShortcutResolver: The host's factory defaults, used to show
    ///     effective before/after values and to skip writes that equal a default.
    /// - Returns: The overrides to write or remove, plus the user bindings kept.
    public func plan(
        from snapshot: ShortcutBindingsSnapshot,
        legacyBindings: [String: StoredShortcut] = [:],
        defaultShortcutResolver: ShortcutDefaultResolver = .builtIn
    ) -> ShortcutKeymapPlan {
        let targetOverrides = overrides
        var changes: [ShortcutKeymapChange] = []
        var kept: [ShortcutAction] = []

        for action in ShortcutAction.allCases {
            let current = snapshot.bindings[action.rawValue]?.canonicalized()
            let managed = current != nil || snapshot.managedActionIDs.contains(action.rawValue)
            let defaultShortcut = (action.defaultShortcut(using: defaultShortcutResolver) ?? .unbound)
                .canonicalized()
            // A file override hides the legacy value; removing it reveals it again.
            let legacyValue = legacyBindings[action.rawValue]?.canonicalized()
            let legacy = managed ? nil : legacyValue
            let before = managed ? (current ?? defaultShortcut) : (legacy ?? defaultShortcut)
            let ownedByPreset = current.map { Self.isPresetValue($0, for: action) } ?? false
            let setByHand = (managed && !ownedByPreset) || legacy != nil

            if let binding = targetOverrides[action], let target = binding.shortcut {
                guard current != target else { continue }
                if !managed && target == before { continue }
                guard !setByHand else {
                    kept.append(action)
                    continue
                }
                changes.append(ShortcutKeymapChange(
                    action: action,
                    before: before,
                    after: target,
                    write: binding,
                    systemConflicts: MacOSSystemShortcut.conflicts(with: target, for: action)
                ))
            } else if ownedByPreset {
                let after = legacyValue ?? defaultShortcut
                changes.append(ShortcutKeymapChange(
                    action: action,
                    before: before,
                    after: after,
                    write: nil,
                    systemConflicts: MacOSSystemShortcut.conflicts(with: after, for: action)
                ))
            }
        }

        return ShortcutKeymapPlan(preset: self, changes: changes, kept: kept)
    }

    /// The preset `snapshot` is currently on, or `nil` when the file mixes
    /// presets.
    ///
    /// A preset is active when switching to it would change nothing and at
    /// least one of its overrides is in the file. Hand-made edits to other
    /// actions, or to a preset's own actions, don't hide the preset.
    public static func active(
        in snapshot: ShortcutBindingsSnapshot,
        legacyBindings: [String: StoredShortcut] = [:],
        defaultShortcutResolver: ShortcutDefaultResolver = .builtIn
    ) -> ShortcutKeymapPreset? {
        for preset in allCases where preset != .cmux {
            let applied = preset.overrides.contains { action, binding in
                snapshot.bindings[action.rawValue]?.canonicalized() == binding.shortcut
            }
            if applied,
               preset.plan(
                   from: snapshot,
                   legacyBindings: legacyBindings,
                   defaultShortcutResolver: defaultShortcutResolver
               ).isEmpty {
                return preset
            }
        }
        return ShortcutKeymapPreset.cmux
            .plan(from: snapshot, legacyBindings: legacyBindings, defaultShortcutResolver: defaultShortcutResolver)
            .isEmpty ? .cmux : nil
    }

    private static func isPresetValue(_ shortcut: StoredShortcut, for action: ShortcutAction) -> Bool {
        allCases.contains { $0.overrides[action]?.shortcut == shortcut }
    }
}
