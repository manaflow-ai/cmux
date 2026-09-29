import AppKit

extension ActionRegistry {
    // MARK: - Shortcuts

    /// The shortcut `id` responds to: user override, else the bound action's
    /// shortcut, else the catalog default.
    public func effectiveShortcut(for id: ActionID) -> Shortcut? {
        let id = canonicalID(for: id)
        if let override = shortcutOverrides[id] { return override }
        return action(for: id)?.shortcut ?? descriptor(for: id)?.defaultShortcut
    }

    /// Keycaps to render for `id`, or nil when it has no shortcut. Handles
    /// labels (vim sequences) and numbered families (`⌘1…9`).
    public func shortcutKeycaps(for id: ActionID) -> [String]? {
        let id = canonicalID(for: id)
        if shortcutOverrides[id] == nil, let label = descriptor(for: id)?.shortcutLabel {
            return label.split(separator: " ").map(String.init)
        }
        guard let shortcut = effectiveShortcut(for: id) else { return nil }
        if shortcutOverrides[id] == nil, descriptor(for: id)?.shortcutFamily == .digits {
            return shortcut.modifierGlyphs + ["1…9"]
        }
        return shortcut.keycaps
    }

    /// Compact text for `id`'s shortcut (`⇧⌘P`), or nil.
    public func shortcutDisplay(for id: ActionID) -> String? {
        guard let caps = shortcutKeycaps(for: id) else { return nil }
        let isSequence = shortcutOverrides[canonicalID(for: id)] == nil && descriptor(for: id)?.shortcutLabel != nil
        return caps.joined(separator: isSequence ? " " : "")
    }

    /// Sets a user override. Pass nil to remove the shortcut entirely.
    public func setShortcutOverride(_ shortcut: Shortcut?, for id: ActionID) {
        shortcutOverrides[canonicalID(for: id)] = .some(shortcut)
    }

    /// Restores the default shortcut.
    public func removeShortcutOverride(for id: ActionID) {
        shortcutOverrides.removeValue(forKey: canonicalID(for: id))
    }

    /// Groups of actions that claim the same shortcut with the same required
    /// context, so neither can win. Different contexts are intentional
    /// overlaps (Cmd-[ is focus back in a terminal and back in a browser).
    public func shortcutConflicts() -> [[ActionID]] {
        var groups: [String: [ActionID]] = [:]
        for descriptor in descriptors {
            guard let shortcut = effectiveShortcut(for: descriptor.id) else { continue }
            let key = "\(shortcut.displayString)|\(descriptor.requires.rawValue)|\(descriptor.shortcutFamily == nil)"
            groups[key, default: []].append(descriptor.id)
        }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0].rawValue < $1[0].rawValue }
    }

    struct ShortcutIndex {
        var byShortcut: [Shortcut: [ActionID]] = [:]
        var digitFamilies: [Shortcut: [ActionID]] = [:]
    }

    func currentShortcutIndex() -> ShortcutIndex {
        if let shortcutIndex { return shortcutIndex }
        var index = ShortcutIndex()
        var ids = descriptors.map(\.id)
        ids += actions.map(\.id).filter { descriptorIndexByID[$0] == nil }
        for id in ids {
            guard let shortcut = effectiveShortcut(for: id) else { continue }
            if shortcutOverrides[id] == nil, descriptor(for: id)?.shortcutFamily == .digits {
                index.digitFamilies[Shortcut("1", modifiers: shortcut.modifiers), default: []].append(id)
            } else {
                index.byShortcut[shortcut, default: []].append(id)
            }
        }
        shortcutIndex = index
        return index
    }
}
