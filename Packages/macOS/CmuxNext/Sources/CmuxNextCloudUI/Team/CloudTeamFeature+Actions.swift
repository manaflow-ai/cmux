import AppKit
public import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// The `cloud.team.*` and `cloud.group.member*` actions (CloudTeamActionCatalog): the Team section's
/// buttons, the palette, the workspace and tab menus, `cmux cloud team-sessions|team-session|
/// copy-session-link|follow|unfollow|reassign|archive-session|team-members|group-members|
/// group-member-set|group-member-remove` and their MCP tools. Each runs one call of the shared
/// ``CloudTeamSessionStore``; a change shows in the Team section on the input's turn (the store
/// changes the row first) and rolls back on a refusal. A refusal reaches a CLI as
/// `{ok:false,error:{code,message}}` with TeamDO's code (`cloud_session.not_yours`, …).
extension CloudTeamFeature {
    public func bind(into registry: ActionRegistry, reason: @escaping @MainActor () -> String?) {
        self.registry = registry
        let store = store
        let host = { [weak self] in self?.host }
        // The publisher starts with the actions it shares the store with, once per app.
        publisher.start()
        func bind(_ id: ActionID, _ run: @escaping @MainActor (ActionInvocation) throws -> @MainActor () async throws -> [String: Any]) {
            let bound = registry.bindEffect(id, unavailable: reason) { invocation in
                let work: @MainActor () async throws -> [String: Any]
                do {
                    work = try run(invocation)
                } catch {
                    // A bad --session or a run with no Cloud target: refused with its code, nothing sent.
                    let refusal = error as? CloudTeamError ?? CloudTeamError(code: "validation.invalid", message: String(describing: error))
                    let failure = ActionWorkFailure(code: refusal.code, reason: refusal.message)
                    return .applied(result: { .failure(failure) })
                }
                return .applied(result: {
                    do {
                        return .success(Self.fields(try await work()))
                    } catch let error as CloudTeamError {
                        return .failure(ActionWorkFailure(code: error.code, reason: error.message))
                    } catch {
                        return .failure(ActionWorkFailure(code: CloudTeamError.unreachable, reason: CloudTeamStrings.unreachable))
                    }
                })
            }
            assert(bound, "\(id) is not in the action catalog")
        }

        bind("cloud.team.sessions") { invocation in
            let scope = invocation["scope"]?.stringValue ?? "team"
            let archived = invocation["archived"]?.boolValue ?? false
            let by = invocation["by"]?.stringValue, cursor = invocation["cursor"]?.stringValue, limit = invocation["limit"]?.intValue
            return { try await store.list(scope: scope, by: by, archived: archived, cursor: cursor, limit: limit) }
        }
        bind("cloud.team.session") { invocation in
            let ref = try Self.session(invocation, host())
            return { try await store.get(ref) }
        }
        bind("cloud.team.copyLink") { invocation in
            let ref = try Self.session(invocation, host())
            let kind = store.row(ref)?.kind ?? ref.kind
            let link = DeepLink(.cloudSession(team: ref.team, machine: ref.vm, session: ref.session, kind: kind)).url(scheme: "cmux")?.absoluteString ?? ""
            // A person's run copies it; a script's run prints it (its pasteboard is the person's).
            let copied = (ActionRunScope.current?.origin ?? invocation.origin) == .user
            if copied {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
            return { ["link": link, "key": ref.key, "kind": kind.wireKind, "copied": copied] }
        }
        for (id, follow) in [("cloud.team.follow", true), ("cloud.team.unfollow", false)] as [(ActionID, Bool)] {
            bind(id) { invocation in
                let ref = try Self.session(invocation, host())
                return { ["session": try await store.setFollowing(ref, follow)] }
            }
        }
        bind("cloud.team.reassign") { invocation in
            let ref = try Self.session(invocation, host())
            guard let to = invocation["to"]?.stringValue?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
                throw CloudTeamError(code: "validation.invalid", message: CloudTeamStrings.memberRequired)
            }
            return { ["session": try await store.reassign(ref, to: to)] }
        }
        bind("cloud.team.archive") { invocation in
            let ref = try Self.session(invocation, host())
            let archived = invocation["archived"]?.boolValue ?? true
            return { ["session": try await store.setArchived(ref, archived)] }
        }
        bind("cloud.team.members") { _ in
            {
                let members = try await store.loadMembers()
                let me = host()?.cloudTeamUserID
                return ["members": members.map { ["user": $0.user, "name": $0.name, "role": $0.role, "you": $0.user == me] as [String: Any] }]
            }
        }
        bind("cloud.group.members") { invocation in
            let group = try Self.groupArgument(invocation)
            return { try await store.groupMembers(group) }
        }
        bind("cloud.group.memberSet") { invocation in
            let group = try Self.groupArgument(invocation)
            guard let user = invocation["user"]?.stringValue, let role = invocation["role"]?.stringValue else {
                throw CloudTeamError(code: "validation.invalid", message: CloudTeamStrings.groupRequired)
            }
            return { try await store.setGroupMember(group, user: user, role: role) }
        }
        bind("cloud.group.memberRemove") { invocation in
            let group = try Self.groupArgument(invocation)
            guard let user = invocation["user"]?.stringValue else {
                throw CloudTeamError(code: "validation.invalid", message: CloudTeamStrings.groupRequired)
            }
            return { try await store.removeGroupMember(group, user: user) }
        }
    }

    /// The session a run names: `--session` (a key or a link), else the Cloud workspace or chat tab
    /// it targets, else the active window's workspace when it is on a Cloud machine.
    static func session(_ invocation: ActionInvocation, _ host: (any CloudTeamHost)?) throws(CloudTeamError) -> CloudTeamSessionStore.Ref {
        if let text = invocation["session"]?.stringValue, !text.isEmpty {
            guard let ref = CloudTeamSessionStore.Ref(text) else {
                throw CloudTeamError(code: CloudTeamError.invalidSession, message: CloudTeamStrings.invalidSession)
            }
            return ref
        }
        let notCloud = CloudTeamError(code: CloudTeamError.notCloud, message: CloudTeamStrings.notCloud)
        guard let host, let team = host.cloudTeamID else { throw notCloud }
        let machines = host.cloudTeamMachines
        let isCloud = { (vm: String) in machines.contains { $0.vm == vm } }
        if let target = invocation.target {
            switch target.kind {
            case .tab:
                for machine in machines {
                    let store = machine.store
                    guard let tab = store.tab(idOrResource: target.id) else { continue }
                    if let chat = tab.agentSession?.session { return .init(team: team, vm: machine.vm, session: chat, kind: .chat) }
                    guard let pane = store.pane(holding: tab), let workspace = store.location(of: pane)?.workspace else { break }
                    return workspaceRef(workspace, team: team, vm: machine.vm)
                }
                throw notCloud
            case .workspace:
                guard let workspace = host.cloudTeamWorkspace(target.id), let vm = host.cloudTeamWorkspaceMachine(target.id), isCloud(vm) else {
                    throw notCloud
                }
                return workspaceRef(workspace, team: team, vm: vm)
            default:
                throw notCloud
            }
        }
        guard let active = host.cloudTeamActiveWorkspace, isCloud(active.machine),
              let workspace = host.cloudTeamWorkspace(active.workspace) else { throw notCloud }
        return workspaceRef(workspace, team: team, vm: active.machine)
    }

    private static func workspaceRef(_ workspace: WorkspaceModel, team: String, vm: String) -> CloudTeamSessionStore.Ref {
        .init(team: team, vm: vm, session: workspace.resourceID?.rawValue ?? workspace.id, kind: .workspace)
    }

    private static func groupArgument(_ invocation: ActionInvocation) throws(CloudTeamError) -> String {
        guard let group = invocation["group"]?.stringValue?.trimmingCharacters(in: .whitespaces), !group.isEmpty else {
            throw CloudTeamError(code: "validation.invalid", message: CloudTeamStrings.groupRequired)
        }
        return group
    }

    /// A reply's JSON as the action's result fields.
    nonisolated static func fields(_ json: [String: Any]) -> [String: ActionResultValue] {
        json.mapValues(value)
    }

    nonisolated static func value(_ any: Any) -> ActionResultValue {
        switch any {
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let array as [Any]: return .array(array.map(value))
        case let object as [String: Any]: return .object(object.mapValues(value))
        default: return .null
        }
    }
}
