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
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon) else { return ctx.refuse(WorkspaceVerbStrings.invalidIcon) }
                return set(.set(icon), on: target)
            }
            guard let anchor = anchor(target, ctx) ?? ctx.refuse(ScreenStrings.iconArgumentRequired) else { return }
            ctx.services.iconPicker.pick(current: target.tab.userIcon, target: "tab:\(target.resource.rawValue)", at: anchor) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon): set(.set(icon), on: target)
                case .clear: set(.clear, on: target)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("tab.clearIcon", invoke: { invocation in
            guard let target = target(invocation, ctx) else { return }
            set(.clear, on: target)
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

    static func set(_ update: FieldUpdate<String>, on target: Target) {
        let resource = target.resource
        target.daemon.send("tab.update") { try await $0.state.updateTabRecord(resource, icon: update) }
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
