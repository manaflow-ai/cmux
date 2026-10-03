import AppKit
import CmuxNextActions

/// What actions mean while a window of its own is key.
///
/// A standalone window is an app window that is not a cmux main window and
/// not owned by one (Debug Settings, the App Store, onboarding, an undocked
/// inspector). It has no tabs, panes or workspaces: it is its own only
/// pane. Before this rule, handlers resolved "the focused object" through
/// `WindowManager.active`, which falls back to the last main window when
/// the key window is not one, so Cmd-W there closed a tab of the main
/// window behind it. The rule runs in the registry before availability,
/// confirmation and the handler (`ActionRegistry.keyWindowRoute`), and
/// menu validation asks it too, so the keyboard and the menu bar agree.
///
/// For a user run without a target:
/// - every close action (the catalog's `close…` ids: Close Tab, Close Pane,
///   Close Workspace, Close Other Workspaces, Close Window...) closes the
///   standalone window, like its close button, whatever key is bound to
///   it. While a sheet or panel over it is key, nothing runs (no refusal,
///   no beep).
/// - other destructive actions on main window content (their targets include
///   a tab, pane, workspace, screen, group or window) are disabled: they
///   would change state the user cannot see. Destructive actions on other
///   objects (an account, a browser profile) run as usual.
nonisolated enum StandaloneWindowRule {
    enum Decision: Equatable, Sendable {
        case pass
        /// Close the standalone window (`performClose`, so its delegate
        /// may decline, as with its close button).
        case closeWindow
        /// A sheet or panel over the standalone window is key: consume.
        case nothing
        case disabled
    }

    /// What the catalog says about an action.
    struct Kind: Equatable, Sendable {
        var closes: Bool
        /// Destructive, and acts on main window content.
        var destroysContent: Bool
    }

    /// Target kinds that live in a main window.
    static let contentTargets: Set<ActionTargetKind> = [
        .tab, .pane, .workspace, .workspaceGroup, .screen, .screenGroup, .tabGroup, .column, .window,
    ]

    /// The key window relative to the standalone window it belongs to.
    enum KeyWindow: Equatable, Sendable {
        /// The standalone window itself, or a page window inside it.
        case standalone
        /// A sheet or panel over a standalone window.
        case overStandalone
    }

    /// A close action: its id's last segment starts with `close`
    /// (`closeTab`, `palette.closeOtherWorkspaces`, `tabGroup.close`).
    static func isClose(_ id: ActionID) -> Bool {
        let last = id.rawValue.split(separator: ".").last ?? ""
        return last.hasPrefix("close")
    }

    @MainActor
    static func kind(_ id: ActionID, registry: ActionRegistry) -> Kind {
        let descriptor = registry.descriptor(for: id)
        let destroysContent = descriptor.map { $0.isDestructive && !contentTargets.isDisjoint(with: $0.targets) } ?? false
        return Kind(closes: isClose(id), destroysContent: destroysContent)
    }

    /// Pure: `keyWindow` is nil when the key window is a main window (or
    /// owned by one), or not ours.
    static func decide(_ kind: Kind, origin: ActionOrigin, hasTarget: Bool, keyWindow: KeyWindow?) -> Decision {
        guard kind.closes || kind.destroysContent, origin == .user, !hasTarget, let keyWindow else { return .pass }
        guard kind.closes else { return .disabled }
        return keyWindow == .standalone ? .closeWindow : .nothing
    }

    /// Whether `invocation` names its object (target or object argument).
    static func hasTarget(_ invocation: ActionInvocation) -> Bool {
        invocation.target != nil
            || ["tab", "pane", "workspace", "window", "group"].contains { invocation[$0]?.targetValue != nil }
    }

    /// Installs the rule on the registry.
    @MainActor
    static func install(_ services: AppServices) {
        services.registry.keyWindowRoute = { [weak services] id, invocation in
            guard let services else { return nil }
            let actionKind = kind(id, registry: services.registry)
            let targeted = hasTarget(invocation)
            // Most runs are neither: decide first, then look up the window.
            guard decide(actionKind, origin: invocation.origin, hasTarget: targeted, keyWindow: .standalone) != .pass,
                  let standalone = services.keyStandaloneWindow else { return nil }
            switch decide(actionKind, origin: invocation.origin, hasTarget: targeted, keyWindow: standalone.keyWindow) {
            case .pass: return nil
            case .closeWindow: return .run { [weak root = standalone.root] in root?.performClose(nil) }
            case .nothing: return .run {}
            case .disabled: return .disabled(reason: MiscHandlerStrings.noPane)
            }
        }
    }
}

extension AppServices {
    /// The standalone window the key window belongs to: the key window and
    /// its sheet or parent chain lead to a root that is titled and
    /// closable and that no main window owns. Nil for main windows, windows
    /// they own (palette, sheets, Chromium page windows, the appearance
    /// studio), a parentless Chromium page window and borderless panels.
    var keyStandaloneWindow: (root: NSWindow, keyWindow: StandaloneWindowRule.KeyWindow)? {
        guard let key = keyWindowSource(), windows.owner(of: key) == nil else { return nil }
        var root = key
        while let up = root.sheetParent ?? root.parent { root = up }
        if root === key, Self.isChromiumPageWindow(key) { return nil }
        guard root.styleMask.isSuperset(of: [.titled, .closable]) else { return nil }
        // A page window inside it (an undocked inspector's page) acts for it.
        let inside = key === root || (key.sheetParent == nil && Self.isChromiumPageWindow(key))
        return (root, inside ? .standalone : .overStandalone)
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}
