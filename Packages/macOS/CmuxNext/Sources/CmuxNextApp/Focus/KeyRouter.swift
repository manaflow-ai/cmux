import AppKit
import CmuxNextActions
import CmuxNextBrowser

/// The one keyboard router (plans/cmux-next/focus.md section 5). Runs from
/// `ShellWindow.performKeyEquivalent` and from Chromium's pre-key hook when
/// a CEF page window is key, so both paths share one order:
///
/// 1. tier 0 (system) actions, always;
/// 2. browser focus mode on the focused page: the page gets the key;
/// 3. tier 1 (navigation) actions;
/// 4. a text input has the keyboard: the field and the Edit menu get it;
/// 5. tier 2 (content) actions whose context matches;
/// 6. the focused view (Ghostty keybinds, the page), then the main menu.
final class KeyRouter: BrowserKeyRouting {
    private unowned let registry: ActionRegistry
    weak var services: AppServices?

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Runs the registry action `event` resolves to when the focus allows
    /// its tier. Returns whether the key was consumed.
    func routeKeyEquivalent(_ event: NSEvent, focus: FocusState) -> Bool {
        guard let resolved = registry.resolveShortcut(for: event), Self.allows(resolved.tier, focus: focus) else { return false }
        return registry.runShortcut(resolved.id, argument: resolved.argument)
    }

    /// Whether an action of `tier` may take a key from the current focus.
    nonisolated static func allows(_ tier: ActionKeyTier, focus: FocusState) -> Bool {
        switch tier {
        case .system: true
        case .navigation: !focus.isBrowserFocusModeActive
        case .content: !focus.isBrowserFocusModeActive && !focus.resolved.isTextInput
        }
    }

    // MARK: Menu key equivalents

    /// Where the key window stands relative to a cmux window.
    enum KeyWindowKind: Equatable {
        /// The cmux window itself, or a Chromium page window over it.
        case content
        /// A panel or sheet over it (palette, rename sheet): its text field
        /// has the keyboard.
        case textPanel
        /// Not ours (no focus to consult).
        case other
    }

    /// Installed as `ActionRegistry.menuKeyEquivalentGate`: a main-menu key
    /// equivalent may run `id` only when its tier may take the key from the
    /// key window's focus, so browser focus mode and text fields keep
    /// chords the router gave them (focus.md section 5).
    func allowsMenuKeyEquivalent(_ id: ActionID) -> Bool {
        let (controller, kind) = keyWindowFocus()
        guard let controller else { return true }
        return Self.allowsMenu(registry.keyTier(for: id), focus: controller.focus.state, keyWindow: kind)
    }

    nonisolated static func allowsMenu(_ tier: ActionKeyTier, focus: FocusState, keyWindow: KeyWindowKind) -> Bool {
        switch keyWindow {
        case .other: true
        case .textPanel: tier != .content
        case .content: allows(tier, focus: focus)
        }
    }

    private func keyWindowFocus() -> (WindowController?, KeyWindowKind) {
        guard let services else { return (nil, .other) }
        // No key window (the app is inactive, or an automation launch):
        // menu actions target the active window, so its focus decides.
        guard let key = NSApp.keyWindow else { return (services.windows.active, .content) }
        let controllers = services.windows.controllers
        if let controller = controllers.first(where: { $0.window === key }) { return (controller, .content) }
        let owner = key.parent ?? key.sheetParent
        guard let controller = controllers.first(where: { $0.window === owner }) else { return (nil, .other) }
        return (controller, key is NSPanel || key.sheetParent != nil ? .textPanel : .content)
    }

    // MARK: BrowserKeyRouting (CEF page window is key)

    func browserTab(_ tab: any BrowserTab, keyEquivalent event: NSEvent) -> BrowserKeyDisposition {
        guard let controller = window(showing: tab) else { return .passToPage }
        return routeKeyEquivalent(event, focus: controller.focus.state) ? .handledByHost : .passToPage
    }

    private func window(showing tab: any BrowserTab) -> WindowController? {
        services?.windows.controllers.first { controller in
            controller.content?.panes.values.contains { pane in
                if case .browser(let entry)? = pane.currentContent { return entry.tab === tab }
                return false
            } ?? false
        }
    }
}
