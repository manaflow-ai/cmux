import CmuxNextActions
import CmuxNextDaemon

/// A resolved screen: its workspace, the daemon that owns it, and the
/// window content showing that workspace (nil when no window shows it).
struct ScreenRef {
    let workspace: WorkspaceModel
    let screen: ScreenModel
    let daemon: DaemonService
    let content: WorkspaceContentController?

    var index: Int { workspace.screens.firstIndex { $0 === screen } ?? 0 }
}

/// A resolved screen group.
struct ScreenGroupRef {
    let workspace: WorkspaceModel
    let group: ScreenGroupSnapshot
    let daemon: DaemonService
    let content: WorkspaceContentController?

    var members: [ScreenModel] { workspace.screens.filter { $0.group == group.id } }
}

// Strict target resolution for screen and screen group actions: an explicit
// target that does not resolve is refused, never replaced by the focus.
extension AppActionContext {
    /// The targeted screen (`screen:<id>`), else the focused window's active screen.
    func screen(_ invocation: ActionInvocation) -> ScreenRef? {
        if let target = invocation.target, target.kind == .screen {
            for daemon in services.machines.daemons {
                for workspace in daemon.store.workspaces {
                    if let screen = workspace.screens.first(where: { $0.id == target.id }) {
                        return ScreenRef(workspace: workspace, screen: screen, daemon: daemon, content: content(showing: workspace))
                    }
                }
            }
            return refuse(RefusalStrings.noScreen(target.id))
        }
        guard let content = focusedContent ?? refuse(RefusalStrings.noWindowShowsWorkspace) else { return nil }
        let active = content.layoutModel.activeScreenID?.rawValue
        guard let screen = content.workspace.screens.first(where: { $0.id == active }) ?? content.workspace.screens.first
            ?? refuse(RefusalStrings.workspaceHasNoScreen) else { return nil }
        return ScreenRef(workspace: content.workspace, screen: screen, daemon: content.daemon, content: content)
    }

    /// The targeted screen group (`screen-group:<id>` or a `group`
    /// argument), else the group of the focused screen.
    func screenGroup(_ invocation: ActionInvocation) -> ScreenGroupRef? {
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap(\.self).first { $0.kind == .screenGroup }
            ?? invocation["group"]?.stringValue.map { ActionTargetRef(kind: .screenGroup, id: $0) }
        if let explicit {
            for daemon in services.machines.daemons {
                for workspace in daemon.store.workspaces {
                    if let group = workspace.screenGroups.first(where: { $0.id.rawValue == explicit.id }) {
                        return ScreenGroupRef(workspace: workspace, group: group, daemon: daemon, content: content(showing: workspace))
                    }
                }
            }
            return refuse(ScreenStrings.noScreenGroup(explicit.id))
        }
        guard let ref = screen(invocation) else { return nil }
        guard let id = ref.screen.group, let group = ref.workspace.screenGroups.first(where: { $0.id == id })
            ?? refuse(ScreenStrings.screenNotInGroup) else { return nil }
        return ScreenGroupRef(workspace: ref.workspace, group: group, daemon: ref.daemon, content: ref.content)
    }

    /// The window content showing `workspace`, if any window shows it.
    func content(showing workspace: WorkspaceModel) -> WorkspaceContentController? {
        services.windows.controllers.lazy.compactMap(\.content).first { $0.workspace === workspace }
    }

    /// Refuses unless `daemon` serves `capability`.
    func require(_ capability: String, on daemon: DaemonService) -> Bool {
        if daemon.supports(capability) { return true }
        refuse(RefusalStrings.needsDaemonCapability(capability))
        return false
    }

    /// The capability name reported when screen state is missing. Screen pins,
    /// colors, icons, order and groups are the daemon's protocol/2 state
    /// resources, addressed by public id (`screen_…`); a daemon without the
    /// workspace registry has none.
    static let screenStateCapability = "screen-state"

    /// Refuses unless `screen` has a public id the state resources accept.
    func requireScreenState(_ screen: ScreenModel) -> Bool {
        if screen.resourceID != nil { return true }
        refuse(RefusalStrings.needsDaemonCapability(Self.screenStateCapability))
        return false
    }

    /// Refuses unless `workspace`'s new screens get public ids.
    func requireScreenState(in workspace: WorkspaceModel) -> Bool {
        if workspace.resourceID != nil { return true }
        refuse(RefusalStrings.needsDaemonCapability(Self.screenStateCapability))
        return false
    }
}
