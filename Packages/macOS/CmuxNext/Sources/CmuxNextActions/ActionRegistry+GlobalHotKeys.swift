extension ActionRegistry {
    /// Bound actions marked `isGlobalHotKey`, with every single-key binding
    /// each takes now (user overrides, else the default). Chords and numbered
    /// families cannot be system-wide hot keys. An action with no single-key
    /// bindings is left out, as is one whose binding's
    /// `isEnabled` is false (Message the Chief from Any App while the Chief
    /// pet is off), which leaves its key to other apps. A global action bound
    /// with `requires:` or `unavailable:` would release its key the same way
    /// while unavailable, so its predicate must read observed state.
    public func globalHotKeys() -> [ActionID: [Shortcut]] {
        // `isBound` reads an unobserved index; reading `actions` makes a
        // later bind or unbind re-run observers of this list.
        _ = actions.count
        var keys: [ActionID: [Shortcut]] = [:]
        for descriptor in descriptors where descriptor.isGlobalHotKey && descriptor.shortcutFamily == nil {
            guard isBound(descriptor.id), action(for: descriptor.id)?.isEnabled() != false else { continue }
            let bindings = configuredShortcuts(for: descriptor.id)
                ?? effectiveShortcut(for: descriptor.id).map { [[$0]] } ?? []
            let strokes = bindings.compactMap { $0.count == 1 ? $0.first : nil }
            if !strokes.isEmpty { keys[descriptor.id] = strokes }
        }
        return keys
    }

    /// True while a shortcut recorder is open: the system-wide hot keys are
    /// released, so pressing one records it instead of running its action.
    public var globalHotKeysSuspended: Bool { context.contains(.recordingShortcut) }
}
