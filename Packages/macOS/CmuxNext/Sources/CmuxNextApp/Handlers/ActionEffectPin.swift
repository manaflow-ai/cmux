import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser

/// The effect a confirmed action has, resolved BEFORE its confirmation shows (cx-zk9t):
/// the object (from focus, when the invocation names none) and every parameter that
/// decides the effect (a page's origin, the exact pending prompt). The confirmation names
/// it, the confirmed run carries it, and the handler acts only on it: a change while the
/// dialog shows (another window activated by automation, a navigation, a new prompt) is
/// refused with `RefusalStrings.changedWhileConfirming`, never applied to something else.
struct ActionEffectPin {
    var target: ActionTargetRef?
    /// What the confirmation shows first: the object's name, or the effect itself.
    var subject: String?
    var arguments: [String: ActionValue] = [:]

    /// The pinned origin of a page action (`browser.pageInfo.*`).
    static let originArgument = "pinnedOrigin"
    /// The pinned prompt of `browser.prompt.allow`.
    static let promptArgument = "pinnedPrompt"

    /// `invocation` carrying this effect.
    func apply(to invocation: ActionInvocation) -> ActionInvocation {
        var pinned = target.map(invocation.retargeted) ?? invocation
        for (name, value) in arguments { pinned.arguments[name] = value }
        return pinned
    }

    /// The effect of `id` for `invocation`, resolved now.
    static func resolve(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) -> ActionEffectPin {
        var pin = ActionEffectPin()
        if invocation.target == nil, let kind = services.registry.descriptor(for: id)?.targets.first,
           let (ref, name) = focused(kind, id, invocation, AppActionContext(services: services)) {
            pin.target = ref
            pin.subject = name
        }
        let context = AppActionContext(services: services)
        let pinned = pin.apply(to: invocation)
        switch id.rawValue {
        case "browser.pageInfo.setPermission", "browser.pageInfo.deleteSiteData":
            guard let entry = try? context.page(pinned), let origin = PageInfoSite(state: entry.tab.state).origin else { break }
            pin.arguments[originArgument] = .string(origin)
            var parts = [origin]
            if let kind = invocation["permission"]?.stringValue.flatMap(SitePermissionKind.init(rawValue:)) {
                parts.insert(kind.displayName, at: 0)
                if let setting = invocation["setting"]?.stringValue.flatMap(SitePermissionSetting.init(rawValue:)) {
                    parts.insert(PageInfoModel.choiceTitle(setting, kind: kind), at: 0)
                }
            }
            pin.subject = parts.joined(separator: " · ")
        case "browser.prompt.allow":
            guard let entry = try? context.page(pinned), let prompt = BrowserPrompt.firstPermission(in: entry.tab.pendingPrompts) else { break }
            pin.arguments[promptArgument] = .string(prompt.id.uuidString)
            pin.subject = prompt.permissionQuestion ?? prompt.origin
        default:
            break
        }
        return pin
    }

    /// The focused object of `kind` and its name.
    private static func focused(_ kind: ActionTargetKind, _ id: ActionID, _ invocation: ActionInvocation,
                                _ context: AppActionContext) -> (ActionTargetRef, String)? {
        let scope = context.scope(invocation)
        switch kind {
        case .machine:
            if id.rawValue.hasPrefix("remote.") {
                guard let session = try? RemoteHandlers.machine(invocation, context) else { return nil }
                return (ActionTargetRef(kind: .machine, id: session.machineID), session.host.label)
            }
            guard let session = try? CloudHandlers.machine(invocation, context) else { return nil }
            return (ActionTargetRef(kind: .machine, id: session.machineID), session.machine.displayName ?? session.machineID)
        case .workspace:
            guard let workspace = scope.workspace else { return nil }
            return (ActionTargetRef(kind: .workspace, id: workspace.id), workspace.displayName)
        case .tab:
            guard let tab = scope.tab else { return nil }
            return (ActionTargetRef(kind: .tab, id: tab.id.rawValue), tab.pane.tab(tab.id)?.displayTitle ?? tab.id.rawValue)
        case .pane:
            guard let pane = scope.pane else { return nil }
            let title = pane.stripModel.selectedID.flatMap { pane.tab($0)?.displayTitle } ?? pane.paneKey
            return (ActionTargetRef(kind: .pane, id: pane.paneKey), title)
        case .tabGroup:
            guard let group = scope.tabGroupID else { return nil }
            return (ActionTargetRef(kind: .tabGroup, id: group), group)
        case .workspaceGroup:
            guard let group = try? context.group(invocation) else { return nil }
            return (ActionTargetRef(kind: .workspaceGroup, id: group.id.rawValue), group.name.isEmpty ? group.id.rawValue : group.name)
        case .profile:
            guard let room = try? context.room(invocation) else { return nil }
            return (ActionTargetRef(kind: .profile, id: room.id.rawValue), room.name)
        case .browserProfile:
            guard let record = try? context.browserProfile(invocation) else { return nil }
            return (ActionTargetRef(kind: .browserProfile, id: record.id), record.name)
        default:
            return nil
        }
    }
}
