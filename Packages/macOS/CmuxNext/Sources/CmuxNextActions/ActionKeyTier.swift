public import AppKit

/// Where an action's shortcut sits in the key routing order
/// (plans/cmux-next/focus.md section 5). Lower tiers run first.
public nonisolated enum ActionKeyTier: Int, Comparable, CaseIterable, Sendable {
    /// App and window control. Always runs: no content, text field or
    /// browser focus mode can capture it.
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

    /// Actions that must always work, even inside a web app in browser
    /// focus mode (the exit chord is one of them).
    static let systemActions: Set<ActionID> = [
        "quit", "closeTab", "closeWorkspace", "closeWindow", "newWindow", "commandPalette",
        "toggleBrowserFocusMode", "openSettings", "showHideAllWindows", "toggleFullScreen",
    ]

    /// Navigation actions that need a content context to be available
    /// (Cmd-L needs a selected browser tab) but still beat text fields.
    static let navigationActions: Set<ActionID> = ["focusBrowserAddressBar"]

    /// Context facts that mean "this action acts on focused content".
    static let contentContexts: ActionContext = [
        .terminalFocused, .browserFocused, .simulatorFocused, .diffViewerFocused, .filePreviewFocused,
        .markdownFocused, .rightSidebarFocused, .fileExplorerFocused, .textBoxFocused, .paletteOpen, .agentPaneFocused,
    ]

    /// The catalog default for `descriptor`.
    static func defaultTier(for descriptor: ActionDescriptor) -> ActionKeyTier {
        if systemActions.contains(descriptor.id) { return .system }
        if navigationActions.contains(descriptor.id) { return .navigation }
        if !descriptor.requires.isDisjoint(with: contentContexts) { return .content }
        return .navigation
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
    /// tier, without running it. Among several candidates the most specific
    /// one wins first (so Cmd-R in a page is reload, not rename), then the
    /// router decides by tier whether it may run now.
    public func resolveShortcut(for event: NSEvent) -> (id: ActionID, argument: String?, tier: ActionKeyTier)? {
        for shortcut in Self.shortcuts(for: event) {
            if let resolved = resolve(shortcut) {
                return (resolved.id, resolved.argument, keyTier(for: resolved.id))
            }
        }
        return nil
    }

    /// Runs a resolved shortcut. Returns whether an action ran.
    @discardableResult
    public func runShortcut(_ id: ActionID, argument: String?) -> Bool {
        if let argument { return perform(id, argument: argument) }
        return perform(id)
    }
}
