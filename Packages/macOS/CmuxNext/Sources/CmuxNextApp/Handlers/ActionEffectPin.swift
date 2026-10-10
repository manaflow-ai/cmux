import CmuxNextActions
import CmuxNextBridge
import CmuxNextAgentPane
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
    /// The pinned warning page URL of `browser.certificateWarning.proceed`.
    static let urlArgument = "pinnedURL"
    /// The pinned permission request of `agentPane.permission.allowOnce` / `allowChat`.
    static let permissionArgument = "pinnedPermission"
    static let pinArguments = [originArgument, promptArgument, urlArgument, permissionArgument]

    /// The target kinds `focused` resolves.
    private static let pinnableKinds: Set<ActionTargetKind> = [.machine, .workspace, .tab, .pane, .tabGroup, .workspaceGroup,
                                                                .profile, .browserProfile]

    /// `invocation` carrying this effect.
    func apply(to invocation: ActionInvocation) -> ActionInvocation {
        var pinned = target.map(invocation.retargeted) ?? invocation
        for (name, value) in arguments { pinned.arguments[name] = value }
        return pinned
    }

    /// Whether a confirmed run of `id` lacks the pin its effect needs (the handlers refuse it).
    static func missesPin(_ id: String, _ invocation: ActionInvocation) -> Bool {
        guard invocation.isPersonConfirmed, let name = requiredArgument[id] else { return false }
        return invocation[name] == nil
    }

    private static let requiredArgument: [String: String] = [
        "browser.pageInfo.setPermission": originArgument, "browser.pageInfo.deleteSiteData": originArgument,
        "browser.prompt.allow": promptArgument, "browser.certificateWarning.proceed": urlArgument,
        "agentPane.permission.allowOnce": permissionArgument, "agentPane.permission.allowChat": permissionArgument,
    ]

    /// The effect of `id` for `invocation`, resolved now; nil when a person-only action's
    /// object or parameter cannot be pinned (the caller refuses before any dialog).
    static func resolve(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async -> ActionEffectPin? {
        var clean = invocation
        // Only what the presenter resolves is pinned: a caller's own pin arguments go (P3).
        for name in pinArguments { clean.arguments[name] = nil }
        var pin = ActionEffectPin()
        let descriptor = services.registry.descriptor(for: id)
        let personOnly = descriptor?.isPersonOnly == true
        let context = AppActionContext(services: services)
        if clean.target == nil, let kind = descriptor?.targets.first, pinnableKinds.contains(kind) {
            if let (ref, name) = focused(kind, id, clean, context) {
                pin.target = ref
                pin.subject = name
            } else if personOnly {
                return nil
            }
        }
        let pinned = pin.apply(to: clean)
        switch id.rawValue {
        case "browser.pageInfo.setPermission", "browser.pageInfo.deleteSiteData":
            guard let entry = try? context.page(pinned), let origin = PageInfoSite(state: entry.tab.state).origin else { return nil }
            pin.arguments[originArgument] = .string(origin)
            var parts = [origin]
            if let kind = clean["permission"]?.stringValue.flatMap(SitePermissionKind.init(rawValue:)) {
                parts.insert(kind.displayName, at: 0)
                if let setting = clean["setting"]?.stringValue.flatMap(SitePermissionSetting.init(rawValue:)) {
                    parts.insert(PageInfoModel.choiceTitle(setting, kind: kind), at: 0)
                }
            }
            pin.subject = parts.joined(separator: " · ")
        case "browser.prompt.allow":
            guard let entry = try? context.page(pinned), let prompt = BrowserPrompt.firstPermission(in: entry.tab.pendingPrompts) else { return nil }
            pin.arguments[promptArgument] = .string(prompt.id.uuidString)
            pin.subject = prompt.permissionQuestion ?? prompt.origin
        case "browser.certificateWarning.proceed":
            guard let entry = try? context.page(pinned), let url = entry.tab.state.url else { return nil }
            pin.arguments[urlArgument] = .string(url.absoluteString)
            pin.subject = url.host() ?? url.absoluteString
        case "agentPane.permission.allowOnce", "agentPane.permission.allowChat":
            guard let pane = context.scope(pinned).pane, let key = pane.currentTabKey,
                  let view = services.agentTabs.existingView(key), let request = await AgentPanePermissionPin.read(view) else { return nil }
            pin.arguments[permissionArgument] = .string(request.argumentText)
            pin.subject = request.title.isEmpty ? nil : request.title
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
