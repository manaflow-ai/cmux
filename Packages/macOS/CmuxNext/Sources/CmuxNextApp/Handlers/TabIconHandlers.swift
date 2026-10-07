import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs

/// `tab.setIcon` and `tab.clearIcon` (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS): the
/// one path behind the tab context menu, the palette, `cmux tab set-icon` and MCP.
/// An `icon` argument sets it; no argument opens the shared icon picker at the
/// tab's chip. The icon lives on the daemon's tab record (`tab.update {icon}`), so
/// every client shows it and it survives restarts.
enum TabIconHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind("tab.setIcon", invoke: { invocation in
            guard let target = target(invocation, ctx) else { return }
            let origin = invocation.origin
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon) else { return ctx.refuse(WorkspaceVerbStrings.invalidIcon) }
                return change(target, to: icon, origin: origin, ctx)
            }
            guard let anchor = anchor(target, ctx) ?? ctx.refuse(ScreenStrings.iconArgumentRequired) else { return }
            ctx.services.iconPicker.pick(current: target.tab.userIcon, target: "tab:\(target.resource.rawValue)", at: anchor) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon): change(target, to: icon, origin: origin, ctx)
                case .clear: change(target, to: nil, origin: origin, ctx)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("tab.clearIcon", invoke: { invocation in
            guard let target = target(invocation, ctx) else { return }
            change(target, to: nil, origin: invocation.origin, ctx)
        })
    }

    /// A tab whose daemon stores tab records (state resources).
    struct Target {
        let tab: TabModel
        let pane: PaneModel
        let resource: ResourceID
        let daemon: DaemonService
    }

    /// The targeted tab (shown or not), else the focused pane's selected tab.
    static func target(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> Target? {
        guard let (tab, pane) = ctx.daemonTab(invocation) else { return nil }
        let daemon = ctx.services.daemon(for: pane)
        guard daemon.store.servesStateResources, let resource = tab.resourceID else {
            return ctx.refuse(daemon.missingCapabilityMessage(DaemonCapabilities.shared.stateResources))
        }
        return Target(tab: tab, pane: pane, resource: resource, daemon: daemon)
    }

    /// Changes the tab's icon (nil removes it); a user's change is an undo step (TabIconHistory).
    static func change(_ target: Target, to icon: String?, origin: ActionOrigin, _ ctx: AppActionContext) {
        // The icon the tab shows now (the picker may have been open while it changed).
        let previous = ctx.services.locateTab(target.tab.id)?.0.userIcon ?? target.tab.userIcon
        // The window that shows the tab, not the picker panel that is key while it closes.
        let window = ctx.services.paneController(for: target.pane)?.view.window ?? NSApp.mainWindow
        let undoManager = window?.undoManager
        history(ctx).change(target.tab.id, from: previous, to: icon, origin: origin, undoManager: undoManager)
    }

    /// Icon updates by tab id, so an undo after the tab moved or its window closed still finds it.
    static func history(_ ctx: AppActionContext) -> TabIconHistory {
        TabIconHistory { id, update in
            guard let (tab, pane) = ctx.services.locateTab(id), let resource = tab.resourceID else { return false }
            let daemon = ctx.services.daemon(for: pane)
            guard daemon.store.servesStateResources else { return false }
            daemon.send("tab.update") { try await $0.state.updateTabRecord(resource, icon: update) }
            return true
        }
    }

    /// The tab's chip in the window that shows it, else the top middle of the active window.
    static func anchor(_ target: Target, _ ctx: AppActionContext) -> IconPickerService.Anchor? {
        if let controller = ctx.services.paneController(for: target.pane) {
            let strip = controller.view.stripView
            if let chip = TabChipAnchor.rect(of: StripTabID(target.tab.id), in: strip) {
                return IconPickerService.Anchor(view: strip, rect: chip)
            }
        }
        return ctx.services.iconPicker.activeWindowAnchor()
    }
}
