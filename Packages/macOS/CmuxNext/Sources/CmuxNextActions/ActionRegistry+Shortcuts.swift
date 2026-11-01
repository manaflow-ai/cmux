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

    /// Sets a user override (replacing any chord and alternates). Pass nil to remove the
    /// shortcut entirely.
    public func setShortcutOverride(_ shortcut: Shortcut?, for id: ActionID) {
        let id = canonicalID(for: id)
        chordOverrides.removeValue(forKey: id)
        alternateShortcuts.removeValue(forKey: id)
        shortcutOverrides[id] = .some(shortcut)
    }

    /// Restores the default shortcut.
    public func removeShortcutOverride(for id: ActionID) {
        let id = canonicalID(for: id)
        chordOverrides.removeValue(forKey: id)
        alternateShortcuts.removeValue(forKey: id)
        shortcutOverrides.removeValue(forKey: id)
    }

    /// Groups of actions that claim the same shortcut with the same required
    /// context, so neither can win. Different contexts are intentional
    /// overlaps (Cmd-[ is focus back in a terminal and back in a browser;
    /// Ctrl-Tab is the next Home chat on Home and the next tab elsewhere).
    public func shortcutConflicts() -> [[ActionID]] {
        shortcutConflictGroups().map(\.ids)
    }

    /// ``shortcutConflicts()`` with the key each group shares: an action's
    /// shortcut or one of its single-key alternates (`{"any": [...]}`).
    public func shortcutConflictGroups() -> [(shortcut: Shortcut, ids: [ActionID])] {
        var groups: [String: (shortcut: Shortcut, ids: [ActionID])] = [:]
        for descriptor in descriptors {
            let alternates = (alternateShortcuts[descriptor.id] ?? []).compactMap { $0.count == 1 ? $0[0] : nil }
            let onHome = KeyBindingDefaults.homeChatScoped.contains(descriptor.id) || KeyBindingDefaults.homeScoped.contains(descriptor.id)
            for shortcut in [effectiveShortcut(for: descriptor.id)].compactMap(\.self) + alternates {
                let key = "\(shortcut.displayString)|\(descriptor.requires.rawValue)|\(descriptor.shortcutFamily == nil)|\(onHome)"
                if groups[key]?.ids.contains(descriptor.id) == true { continue }
                groups[key, default: (shortcut, [])].ids.append(descriptor.id)
            }
        }
        return groups.values.filter { $0.ids.count > 1 }.sorted { ($0.ids[0].rawValue, $0.shortcut.displayString) < ($1.ids[0].rawValue, $1.shortcut.displayString) }
    }

    /// Every key cmux.json gives `id`, in its order: the override (one key
    /// or a chord), then its alternates. Nil when cmux.json does not set it.
    public func configuredShortcuts(for id: ActionID) -> [[Shortcut]]? {
        let id = canonicalID(for: id)
        let primary: [Shortcut]
        if let chord = chordOverrides[id] {
            primary = [chord.first, chord.second]
        } else if let override = shortcutOverrides[id] {
            guard let override else { return [] }
            primary = [override]
        } else {
            return nil
        }
        return [primary] + (alternateShortcuts[id] ?? [])
    }

    /// Sets `keys` as `id`'s override and alternates, in order (a repeated
    /// key counts once); none removes its shortcut.
    public func setConfiguredShortcuts(_ keys: [[Shortcut]], for id: ActionID) {
        let keys = keys.reduce(into: [[Shortcut]]()) { if !$0.contains($1) { $0.append($1) } }
        guard let primary = keys.first else { return setShortcutOverride(nil, for: id) }
        if primary.count == 2 {
            setChordOverride(ShortcutChord(primary[0], primary[1]), for: id)
        } else {
            setShortcutOverride(primary[0], for: id)
        }
        setAlternateShortcuts(Array(keys.dropFirst()), for: id)
    }

    /// Sets the keys after `id`'s override (`{"any": [...]}`); an empty
    /// list removes them.
    public func setAlternateShortcuts(_ keys: [[Shortcut]], for id: ActionID) {
        let id = canonicalID(for: id)
        alternateShortcuts[id] = keys.isEmpty ? nil : keys
    }

    func currentShortcutIndex() -> ShortcutIndex {
        if let shortcutIndex { return shortcutIndex }
        var index = ShortcutIndex()
        var ids = descriptors.map(\.id)
        ids += actions.map(\.id).filter { descriptorIndexByID[$0] == nil }
        for id in ids where disabledFeature(for: id) == nil { // DisabledFeatures: no key, chord or leader row
            let alternates = (alternateShortcuts[id] ?? []).compactMap { $0.count == 2 ? ShortcutChord($0[0], $0[1]) : nil }
            for chord in [effectiveChord(for: id)].compactMap(\.self) + alternates {
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
