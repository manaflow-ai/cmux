import AppKit

/// The core switching keys as the live binding table has them (Home's
/// first-run "Switching" card): tabs and workspaces by number, next and
/// previous tab and workspace, and focus Back / Forward.
///
/// Read from ``RegistryKeyBindings/table``, so a cmux.json or
/// keybindings.json rebind, a removal and a key the Ghostty config claims
/// all show as the key that runs now. A key nothing runs is nil.
///
/// ```swift
/// let keys = SwitchingShortcuts(registry: registry)
/// keys.tabByNumber        // "⌃1…9"
/// keys.nextPreviousTab    // "⇧⌘[ ⇧⌘]"
/// ```
public nonisolated struct SwitchingShortcuts: Sendable, Equatable {
    /// Select Tab 1…9 in the focused pane (`selectSurfaceByNumber`, default `⌃1…9`).
    public var tabByNumber: String?
    /// Select Workspace 1…9 (`selectWorkspaceByNumber`, default `⌘1…9`).
    public var workspaceByNumber: String?
    /// Previous and next tab (`prevSurface` / `nextSurface`, default `⇧⌘[ ⇧⌘]`).
    public var nextPreviousTab: String?
    /// Previous and next workspace (`prevSidebarTab` / `nextSidebarTab`, default `⌃⌘[ ⌃⌘]`).
    public var nextPreviousWorkspace: String?
    /// Focus Back and Forward (`focusHistoryBack` / `focusHistoryForward`, default `⌘[ ⌘]`).
    public var focusBackForward: String?
    /// The modifiers (`NSEvent.ModifierFlags` raw value, device independent)
    /// of the tabs-by-number key, for the Mission Control check; nil when it
    /// is a chord or unbound.
    public var tabByNumberModifiers: UInt?

    /// Creates the summary from explicit values (tests, previews).
    public init(tabByNumber: String? = nil, workspaceByNumber: String? = nil, nextPreviousTab: String? = nil,
                nextPreviousWorkspace: String? = nil, focusBackForward: String? = nil, tabByNumberModifiers: UInt? = nil) {
        self.tabByNumber = tabByNumber
        self.workspaceByNumber = workspaceByNumber
        self.nextPreviousTab = nextPreviousTab
        self.nextPreviousWorkspace = nextPreviousWorkspace
        self.focusBackForward = focusBackForward
        self.tabByNumberModifiers = tabByNumberModifiers
    }

    /// Reads the keys from `registry`'s live binding table.
    /// - Parameter registry: The app's action registry (overrides and key binding layers applied).
    @MainActor
    public init(registry: ActionRegistry) {
        let entries = RegistryKeyBindings(registry).table.entries.filter { !$0.source.isGhostty }
        func display(_ binding: KeyBinding, _ id: ActionID) -> String {
            guard let last = binding.keys.last else { return "" }
            let prefix = binding.keys.dropLast().map(\.displayString)
            return (prefix + [registry.shortcutDisplay(last, for: id)]).joined(separator: " ")
        }
        /// The key a person reads for `id`: a user entry (cmux.json,
        /// keybindings.json) first, else the documented default, else the
        /// last entry the table has.
        func binding(_ id: ActionID, preferred: Shortcut?, digit: Bool) -> KeyBinding? {
            let id = registry.canonicalID(for: id)
            let mine = entries.filter { entry in
                guard entry.command == id else { return false }
                return digit ? entry.keys.last?.key == "1" && (entry.argument == "1" || entry.argument == nil) : entry.argument == nil
            }
            return mine.last { $0.source == .user } ?? mine.first { $0.keys.count == 1 && $0.keys.first == preferred } ?? mine.last
        }
        func key(_ id: ActionID, _ preferred: Shortcut) -> String? {
            binding(id, preferred: preferred, digit: false).map { display($0, id) }
        }
        func pair(_ previous: String?, _ next: String?) -> String? {
            let both = [previous, next].compactMap { $0 }
            return both.isEmpty ? nil : both.joined(separator: " ")
        }
        let tabs = binding("selectSurfaceByNumber", preferred: nil, digit: true)
        tabByNumber = tabs.map { display($0, "selectSurfaceByNumber") }
        tabByNumberModifiers = tabs.flatMap { $0.keys.count == 1 ? $0.keys[0].modifiers.rawValue : nil }
        workspaceByNumber = binding("selectWorkspaceByNumber", preferred: nil, digit: true).map { display($0, "selectWorkspaceByNumber") }
        nextPreviousTab = pair(key("prevSurface", Shortcut("[", modifiers: [.command, .shift])),
                               key("nextSurface", Shortcut("]", modifiers: [.command, .shift])))
        nextPreviousWorkspace = pair(key("prevSidebarTab", Shortcut("[", modifiers: [.control, .command])),
                                     key("nextSidebarTab", Shortcut("]", modifiers: [.control, .command])))
        focusBackForward = pair(key("focusHistoryBack", Shortcut("[", modifiers: [.command])),
                                key("focusHistoryForward", Shortcut("]", modifiers: [.command])))
    }
}
