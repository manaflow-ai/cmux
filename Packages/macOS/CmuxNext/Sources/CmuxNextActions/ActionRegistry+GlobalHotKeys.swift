extension ActionRegistry {
    /// Bound actions marked `isGlobalHotKey`, with the shortcut each takes
    /// now (user override, else the default). An action whose shortcut was
    /// removed, or replaced by a chord, is left out: a chord or a numbered
    /// family cannot be one system-wide hot key.
    public func globalHotKeys() -> [ActionID: Shortcut] {
        // `isBound` reads an unobserved index; reading `actions` makes a
        // later bind or unbind re-run observers of this list.
        _ = actions.count
        var keys: [ActionID: Shortcut] = [:]
        for descriptor in descriptors where descriptor.isGlobalHotKey && descriptor.shortcutFamily == nil {
            guard isBound(descriptor.id), let shortcut = effectiveShortcut(for: descriptor.id) else { continue }
            keys[descriptor.id] = shortcut
        }
        return keys
    }
}
