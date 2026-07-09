public import AppKit
public import Foundation

/// Owns the stateless application/dock menu-building decisions, lifted out of the
/// `@main` app target so menu structure stops living as inline `NSMenu` assembly
/// on the delegate. Emits Sendable value specs (``DockMenuSpec``); the live
/// `NSMenu`/`NSMenuItem` materialization, the `@objc` selector wiring, and
/// `String(localized:)` title resolution stay app-side in the witness.
///
/// Generic over the concrete host and weak-refs it (mirrors
/// ``WindowLifecycleCoordinator``) so the delegate ↔ coordinator reference is
/// one-directional in ownership: the delegate owns this coordinator strongly,
/// this coordinator weak-refs back, so there is no retain cycle. The host is not
/// read by the current stateless decision; it is held so future menu-validation
/// decisions can reach app-side leaf state through the seam.
///
/// `@MainActor` because the dock menu is built from AppKit's
/// `applicationDockMenu(_:)` callback on the main thread, so the decision lives
/// where its caller lives.
@MainActor
public final class AppMenuCoordinator<Host: AppMenuHosting> {
    /// App-side menu-validation seam, held weakly so the delegate ↔ coordinator
    /// ownership stays one-directional (the delegate owns this coordinator
    /// strongly).
    public weak var host: Host?

    public init(host: Host) {
        self.host = host
    }

    /// The dock menu shown when the user right-clicks the app's Dock icon: a
    /// single "New Window" item whose already-localized title the caller passes
    /// in via `newWindowTitle`. The witness materializes the returned spec into
    /// an `NSMenu` and wires `openNewMainWindow(_:)`.
    public func dockMenuSpec(newWindowTitle: String) -> DockMenuSpec {
        DockMenuSpec(items: [
            AppMenuItemSpec(
                title: newWindowTitle,
                keyEquivalent: "",
                modifierMask: [],
                action: .newMainWindow
            ),
        ])
    }

    /// Locates the Reload-Configuration item within the app menu's items: the
    /// first item whose identifier matches `identifier`, else the first item
    /// whose title matches `localizedTitle`, else `nil`. The witness walks the
    /// live `NSMenu`, passes each item's `(identifier?.rawValue, title)` pair in
    /// order, and maps the returned index back to the concrete `NSMenuItem`; the
    /// stable identifier and the already-localized title stay app-side.
    public func locateReloadConfigurationItem(
        in items: [(identifier: String?, title: String)],
        identifier: String,
        localizedTitle: String
    ) -> Int? {
        if let index = items.firstIndex(where: { $0.identifier == identifier }) {
            return index
        }
        return items.firstIndex(where: { $0.title == localizedTitle })
    }

    /// Resolves the key-equivalent and modifier mask to assign to the
    /// Reload-Configuration menu item from the configured shortcut: when the
    /// shortcut yields a non-nil `menuItemKeyEquivalent`, that equivalent plus
    /// `modifierMask`; otherwise the cleared `("", [])` pair. The witness reads
    /// `KeyboardShortcutSettings.menuShortcut(for: .reloadConfiguration)`
    /// app-side, passes its `menuItemKeyEquivalent`/`modifierFlags`, and applies
    /// the returned values onto the live `NSMenuItem`.
    public func reloadConfigurationKeyEquivalent(
        menuItemKeyEquivalent: String?,
        modifierMask: NSEvent.ModifierFlags
    ) -> (keyEquivalent: String, modifierMask: NSEvent.ModifierFlags) {
        if let menuItemKeyEquivalent {
            return (keyEquivalent: menuItemKeyEquivalent, modifierMask: modifierMask)
        }
        return (keyEquivalent: "", modifierMask: [])
    }

    /// Resolves the ordered new-workspace context-menu items from the configured
    /// list: drops a leading separator and any separator that immediately
    /// follows another separator, trims trailing separators, and returns `nil`
    /// when no non-separator item remains (so the witness presents nothing). The
    /// witness maps each `CmuxResolvedConfigContextMenuItem` to a
    /// ``NewWorkspaceContextMenuItemInput`` first, then materializes each
    /// returned ``NewWorkspaceContextMenuItemPlan`` into an `NSMenuItem` (icon
    /// render, `representedObject`, `target`/`action`), recovering the resolved
    /// action via `actionIndex`, and pops the live `NSMenu`.
    public func planNewWorkspaceContextMenu(
        items: [NewWorkspaceContextMenuItemInput]
    ) -> [NewWorkspaceContextMenuItemPlan]? {
        var ordered: [NewWorkspaceContextMenuItemPlan] = []
        for item in items {
            switch item {
            case .separator:
                if let last = ordered.last, case .action = last {
                    ordered.append(.separator)
                }
            case let .action(title, tooltip, iconSourcePath, actionIndex):
                ordered.append(.action(
                    title: title,
                    tooltip: tooltip,
                    iconSourcePath: iconSourcePath,
                    actionIndex: actionIndex
                ))
            }
        }
        while case .separator? = ordered.last {
            ordered.removeLast()
        }
        guard ordered.contains(where: { plan in
            if case .action = plan { return true }
            return false
        }) else {
            return nil
        }
        return ordered
    }

    /// Decides whether a menu item should validate as enabled. The policy is
    /// unconditional: user-initiated update checks are always allowed and every
    /// other item is unconditionally valid (preserving the prior
    /// `UpdateController.validateMenuItem` behavior). The witness reads the live
    /// item's action selector app-side and passes its name (or `nil`) through;
    /// the result drives `NSMenuItemValidation.validateMenuItem(_:)`.
    public func isMenuItemValid(actionSelectorName: String?) -> Bool {
        true
    }

    /// Walks a value-tree snapshot of a live menu and returns the `IndexPath`s of
    /// every item (at any depth) whose action selector name equals `selectorName`,
    /// in depth-first pre-order. Each `IndexPath` indexes `nodes`, then the matched
    /// node's `submenu`, and so on, so the witness can map each path back onto the
    /// concrete `NSMenuItem` and clear its key equivalent / modifier mask and
    /// disable it. A node is recorded before its descendants, matching the prior
    /// recursive `disableMenuItemShortcut(in:action:)` traversal order.
    public func menuItemPathsToDisable(
        in nodes: [MenuItemValidationNode],
        matching selectorName: String
    ) -> [IndexPath] {
        var paths: [IndexPath] = []
        appendMenuItemPathsToDisable(
            in: nodes,
            matching: selectorName,
            prefix: IndexPath(),
            into: &paths
        )
        return paths
    }

    private func appendMenuItemPathsToDisable(
        in nodes: [MenuItemValidationNode],
        matching selectorName: String,
        prefix: IndexPath,
        into paths: inout [IndexPath]
    ) {
        for (index, node) in nodes.enumerated() {
            let path = prefix.appending(index)
            if node.actionSelectorName == selectorName {
                paths.append(path)
            }
            if let submenu = node.submenu {
                appendMenuItemPathsToDisable(
                    in: submenu,
                    matching: selectorName,
                    prefix: path,
                    into: &paths
                )
            }
        }
    }

    /// Decides whether a stale built-in `cmux` menu key-equivalent must be
    /// suppressed before AppKit's menu machinery consumes the keystroke, given a
    /// ``StaleMenuShortcutContext`` the witness assembled from the live `NSEvent`.
    ///
    /// The verdict reproduces the legacy inline decision exactly: a non-key event,
    /// an armed recorder, a panel/modal/sheet target, or a non-command event never
    /// suppresses; otherwise, when at least one action's *default* shortcut matches
    /// the event, suppression is granted unless that action's *current* shortcut
    /// already matches (a live binding), with the close-action family suppressed
    /// even when no current shortcut matches, and any live current-shortcut match
    /// across all actions vetoing suppression. The witness reads
    /// `KeyboardShortcutSettings.Action`, the recorder activity, and the
    /// key-window/modal/sheet state app-side and passes them through; this method
    /// owns only the boolean branching.
    public func shouldSuppressStaleMenuShortcut(context: StaleMenuShortcutContext) -> Bool {
        guard context.isKeyDown else { return false }
        if context.anyRecorderActive { return false }
        if context.isPanelOrModalOrSheet { return false }
        guard context.hasCommandFlag else { return false }

        guard !context.staleDefaultActions.isEmpty else { return false }

        for action in context.staleDefaultActions {
            if action.currentShortcutMatchesEvent {
                return false
            }
        }

        if context.staleDefaultActions.contains(where: \.isCloseAction) {
            return true
        }

        if context.anyCurrentShortcutMatchesEvent {
            return false
        }
        return true
    }
}
