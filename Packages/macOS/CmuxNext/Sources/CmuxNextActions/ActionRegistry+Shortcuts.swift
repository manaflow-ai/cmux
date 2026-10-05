import AppKit

extension ActionRegistry {
    // MARK: - Shortcuts

    /// The shortcut `id` responds to: user override, else the bound action's
    /// shortcut, else the catalog default. Nil when a chord replaces it.
    public func effectiveShortcut(for id: ActionID) -> Shortcut? {
        let id = canonicalID(for: id)
        if chordOverrides[id] != nil { return nil }
        if let override = shortcutOverrides[id] { return override }
        return action(for: id)?.shortcut ?? descriptor(for: id)?.defaultShortcut
    }

    /// Keycaps to render for `id`, or nil when it has no shortcut. Handles
    /// labels (vim sequences), chords (`⌃B` then `C`) and numbered families
    /// (`⌘1…9`).
    public func shortcutKeycaps(for id: ActionID) -> [String]? {
        let id = canonicalID(for: id)
        if let chord = chordOverrides[id] ?? LeaderLayer(registry: self).shownDefaultChord(for: id) {
            guard isDigitFamily(id, chord.second) else { return chord.keycaps }
            return chord.first.keycaps + chord.second.modifierGlyphs + ["1…9"]
        }
        if shortcutOverrides[id] == nil, let label = descriptor(for: id)?.shortcutLabel {
            return label.split(separator: " ").map(String.init)
        }
        guard let shortcut = effectiveShortcut(for: id) else { return nil }
        if isDigitFamily(id, shortcut) {
            return shortcut.modifierGlyphs + ["1…9"]
        }
        return shortcut.keycaps
    }

    /// A numbered family (`⌘1…9`) keyed by its `1`, also when cmux.json
    /// moves it (`cmd+opt+1`, or `["ctrl+b", "1"]`).
    func isDigitFamily(_ id: ActionID, _ shortcut: Shortcut) -> Bool {
        descriptor(for: id)?.shortcutFamily == .digits && shortcut.key == "1"
    }

    /// Compact text for `id`'s shortcut (`⇧⌘P`), or nil.
    public func shortcutDisplay(for id: ActionID) -> String? {
        let id = canonicalID(for: id)
        if let chord = chordOverrides[id] ?? LeaderLayer(registry: self).shownDefaultChord(for: id) { return shortcutDisplay(chord, for: id) }
        guard let caps = shortcutKeycaps(for: id) else { return nil }
        let isSequence = shortcutOverrides[id] == nil && descriptor(for: id)?.shortcutLabel != nil
        return caps.joined(separator: isSequence ? " " : "")
    }

    /// How `shortcut` reads as `id`'s shortcut: `⌥⌘1…9` for a numbered
    /// family.
    public func shortcutDisplay(_ shortcut: Shortcut, for id: ActionID) -> String {
        guard isDigitFamily(canonicalID(for: id), shortcut) else { return shortcut.displayString }
        return (shortcut.modifierGlyphs + ["1…9"]).joined()
    }

    /// How `chord` reads as `id`'s shortcut: `⌃B C`, or `⌃B 1…9`.
    public func shortcutDisplay(_ chord: ShortcutChord, for id: ActionID) -> String {
        chord.first.displayString + " " + shortcutDisplay(chord.second, for: id)
    }

    /// Sets a user override (replacing any chord). Pass nil to remove the
    /// shortcut entirely.
    public func setShortcutOverride(_ shortcut: Shortcut?, for id: ActionID) {
        let id = canonicalID(for: id)
        chordOverrides.removeValue(forKey: id)
        shortcutOverrides[id] = .some(shortcut)
    }

    /// Restores the default shortcut.
    public func removeShortcutOverride(for id: ActionID) {
        let id = canonicalID(for: id)
        chordOverrides.removeValue(forKey: id)
        shortcutOverrides.removeValue(forKey: id)
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

    func currentShortcutIndex() -> ShortcutIndex {
        if let shortcutIndex { return shortcutIndex }
        var index = ShortcutIndex()
        var ids = descriptors.map(\.id)
        ids += actions.map(\.id).filter { descriptorIndexByID[$0] == nil }
        for id in ids where disabledFeature(for: id) == nil { // DisabledFeatures: no key, chord or leader row
            if let chord = effectiveChord(for: id) {
                if isDigitFamily(id, chord.second) {
                    index.chordDigitFamilies[chord.first, default: [:]][chord.second, default: []].append(id)
                } else {
                    index.chords[chord.first, default: [:]][chord.second, default: []].append(id)
                }
            }
        }
        shortcutIndex = index
        return index
    }
}
