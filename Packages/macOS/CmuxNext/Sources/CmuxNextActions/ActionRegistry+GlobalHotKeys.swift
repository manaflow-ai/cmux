extension ActionRegistry {
    /// Bound actions marked `isGlobalHotKey`, with the shortcut each takes
    /// now (user override, else the default). An action whose shortcut was
    /// removed, or replaced by a chord, is left out: a chord or a numbered
    /// family cannot be one system-wide hot key. So is one whose binding's
    /// `isEnabled` is false (Message the Chief from Any App while the Chief
    /// pet is off), which leaves its key to other apps. A global action bound
    /// with `requires:` or `unavailable:` would release its key the same way
    /// while unavailable, so its predicate must read observed state.
    public func globalHotKeys() -> [ActionID: Shortcut] {
        // `isBound` reads an unobserved index; reading `actions` makes a
        // later bind or unbind re-run observers of this list.
        _ = actions.count
        var keys: [ActionID: Shortcut] = [:]
        for descriptor in descriptors where descriptor.isGlobalHotKey && descriptor.shortcutFamily == nil {
            guard isBound(descriptor.id), action(for: descriptor.id)?.isEnabled() != false,
                  let shortcut = effectiveShortcut(for: descriptor.id) else { continue }
            keys[descriptor.id] = shortcut
        }
        return keys
    }

    /// True while a shortcut recorder is open: the system-wide hot keys are
    /// released, so pressing one records it instead of running its action.
    public var globalHotKeysSuspended: Bool { context.contains(.recordingShortcut) }
}
