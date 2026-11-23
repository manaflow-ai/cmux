public import AppKit

/// Where an action's shortcut sits in the key routing order
/// (plans/cmux-next/focus.md section 5). Lower tiers run first.
public nonisolated enum ActionKeyTier: Int, Comparable, CaseIterable, Sendable {
    /// App and window control. Always runs: no content or text field can
    /// capture it. Browser focus mode gives these keys to the page too,
    /// except its own toggle and Quit (the key router's rule).
    case system = 0
    /// Navigation and layout. Beats terminal keybinds, page shortcuts and
    /// text fields; yields to browser focus mode.
    case navigation = 1
    /// Acts on the focused content. Runs only when that content has the
    /// keyboard, never while a text field does.
    case content = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `cmux.json` `shortcuts.tiers.<actionID>` value.
    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "system", "0": self = .system
        case "navigation", "1": self = .navigation
        case "content", "2": self = .content
        default: return nil
        }
    }

    public var configValue: String {
        switch self {
        case .system: "system"
        case .navigation: "navigation"
        case .content: "content"
        }
    }

    /// The catalog default for `descriptor`: Rust's table (cmux-action-catalog `key_tiers`),
    /// navigation when it lists none.
    static func defaultTier(for descriptor: ActionDescriptor) -> ActionKeyTier {
        RustActionCatalog.shared.keyTiers[descriptor.id] ?? .navigation
    }
}

extension ActionRegistry {
    /// The effective tier of `id`: the user's `cmux.json` override, else the
    /// catalog default. Runtime actions without a descriptor are navigation.
    public func keyTier(for id: ActionID) -> ActionKeyTier {
        let id = canonicalID(for: id)
        if let override = keyTierOverrides[id] { return override }
        return descriptor(for: id).map(ActionKeyTier.defaultTier(for:)) ?? .navigation
    }

    /// Sets (or with nil clears) the user's tier for `id`.
    public func setKeyTierOverride(_ tier: ActionKeyTier?, for id: ActionID) {
        keyTierOverrides[canonicalID(for: id)] = tier
    }

    /// The action a key-down resolves to in the current context, with its
    /// tier, without running it: the binding table's winner
    /// (``RegistryKeyBindings/table``, as the key router resolves), so a
    /// more specific entry wins (Cmd-R in a page is reload, not rename);
    /// the router then decides by tier whether it may run now.
    public func resolveShortcut(for event: NSEvent) -> (id: ActionID, argument: String?, tier: ActionKeyTier)? {
        let bindings = RegistryKeyBindings(self)
        let table = bindings.table, bits = context
        for shortcut in Self.shortcuts(for: event) {
            if let winner = table.resolve([shortcut], in: KeyContext(bits: bits), isRunnable: { bindings.canPerform($0, in: bits) }).winner {
                return (winner.command, winner.argument, keyTier(for: winner.command))
            }
        }
        return nil
    }
}
