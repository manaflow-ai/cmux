import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
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
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon) else { return ctx.refuse(WorkspaceVerbStrings.invalidIcon) }
                return change(target, to: icon, origin: invocation.origin, ctx)
            }
            guard let anchor = anchor(target, ctx) ?? ctx.refuse(ScreenStrings.iconArgumentRequired) else { return }
            // A pick in the picker is the person's own gesture, also when automation opened it.
            ctx.services.iconPicker.pick(current: target.tab.userIcon, target: "tab:\(target.resource.rawValue)", at: anchor) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon): change(target, to: icon, origin: .user, ctx)
                case .clear: change(target, to: nil, origin: .user, ctx)
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

    /// The id of the tab icon undo toast (one per window; a newer change replaces it).
    static let undoToastID = "tab-icon-undo"

    /// Changes the tab's icon (nil removes it); a user's change offers an undo toast (TabIconHistory).
    static func change(_ target: Target, to icon: String?, origin: ActionOrigin, _ ctx: AppActionContext) {
        // The icon the tab shows now (the picker may have been open while it changed).
        let previous = ctx.services.locateTab(target.tab.id)?.0.userIcon ?? target.tab.userIcon
        history(ctx).change(target.tab.id, from: previous, to: icon, origin: origin)
    }

    /// Icon updates by tab id, so an undo after the tab moved still finds it; the undo toast shows
    /// in the window that shows the tab (not the picker panel that is key while it closes).
    static func history(_ ctx: AppActionContext) -> TabIconHistory {
        let shownIn = UndoToastWindow()
        return TabIconHistory(apply: { id, update in
            guard let (tab, pane) = ctx.services.locateTab(id), let resource = tab.resourceID else { return false }
            let daemon = ctx.services.daemon(for: pane)
            guard daemon.store.servesStateResources else { return false }
            daemon.send("tab.update") { try await $0.state.updateTabRecord(resource, icon: update) }
            shownIn.window = ctx.services.paneController(for: pane)?.view.window
            return true
        }, offerUndo: { message, undo in
            let windows = ctx.services.windows
            guard let window = shownIn.window ?? windows?.active?.window ?? NSApp.mainWindow else { return }
            let handle = CmuxToastCenter.shared.show(CmuxToast(id: undoToastID, message: message, action: .undo()), in: window)
            handle.onAction = { undo() }
        })
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

/// The window of the tab whose icon changed last (weak: a closed window shows no toast there).
@MainActor
final class UndoToastWindow {
    weak var window: NSWindow?
}
