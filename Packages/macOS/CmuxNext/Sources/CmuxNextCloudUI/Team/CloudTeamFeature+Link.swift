public import CmuxNextActions
import CmuxNextDaemon
public import CmuxNextDesign
import Foundation

/// `link.open` for a team Cloud link (DeepLinkNavigator calls ``CloudTeamFeature/openLink(team:machine:session:kind:intent:)``) (`cmux://cloud/session|workspace/<team>/<vm>/<id>`, contract C5).
///
/// The record lives in the team's TeamDO, so this reads it as the signed-in person
/// (`team.cloud.session.get` with `x-cmux-team`) and then shows it: the workspace or chat tab this
/// Mac already has open on that machine. A teammate's session has no route from this Mac yet (lane C
/// attaches only the owner's own machine and a chat its owner shared), so it refuses with
/// `cloud_session.attach_unavailable` instead of pretending to open it. Every refusal carries its code
/// for `cmux link open --json`.
extension CloudTeamFeature {
    public func openLink(team: String, machine: String, session: String, kind: DeepLink.CloudSessionKind,
                         intent: WindowActivation.Intent) {
        let ref = CloudTeamSessionStore.Ref(team: team, vm: machine, session: session, kind: kind)
        guard let registry, let host else { return }
        let store = store
        // task-owner: the link's one read of its record, then one reveal or refusal; the registry tracks it.
        registry.track(Task { [weak self] () -> ActionWorkFailure? in
            var reply: [String: Any]?
            var code: String?
            do {
                reply = try await store.get(ref)
            } catch let error as CloudTeamError {
                code = error.code
            } catch {
                code = nil
            }
            guard let self else { return nil }
            let plan = DeepLink.cloudSessionPlan(team: team, reply: reply, errorCode: code, signedIn: host.cloudTeamSignedIn) { kind, vm, id in
                Self.shown(kind, vm: vm, id: id, host: host) != nil
            }
            return show(plan, owner: (reply?["session"] as? [String: Any])?["owner"] as? String, intent: intent, host: host)
        })
    }

    /// Shows the plan's target, or the refusal (shown to a person, returned with its code to a caller).
    func show(_ plan: DeepLink.CloudSessionPlan, owner: String?, intent: WindowActivation.Intent,
              host: any CloudTeamHost) -> ActionWorkFailure? {
        switch plan {
        case .reveal(let kind, let vm, let id):
            switch Self.shown(kind, vm: vm, id: id, host: host) {
            case .tab(let tab)?:
                if host.cloudTeamRevealTab(tab, intent: intent) { return nil }
            case .workspace(let workspace)?:
                if host.cloudTeamRevealWorkspace(workspace, intent: intent) { return nil }
            case nil: break
            }
            return refuse("cloud_session.not_found", CloudTeamStrings.gone)
        case .attach(_, _, let vm, _):
            // The person's own machine, not connected here: connecting is theirs to start.
            if owner != nil, owner == host.cloudTeamUserID, host.cloudTeamMachines.contains(where: { $0.vm == vm }) {
                return refuse("cloud_session.not_open_here", CloudTeamStrings.notOpenHere)
            }
            return refuse(CloudTeamError.attachUnavailable, CloudTeamStrings.attachUnavailable)
        case .notMember: return refuse("team.not_member", CloudTeamStrings.notMember)
        case .gone: return refuse("cloud_session.not_found", CloudTeamStrings.gone)
        case .unreachable: return refuse(CloudTeamError.unreachable, CloudTeamStrings.unreachable)
        case .signedOut: return refuse(CloudTeamError.signedOut, CloudTeamStrings.signedOut)
        }
    }

    enum Shown {
        case tab(String)
        case workspace(String)
    }

    /// The tab (a chat) or the workspace (its local key) this Mac shows for the session on machine `vm`.
    static func shown(_ kind: DeepLink.CloudSessionKind, vm: String, id: String, host: any CloudTeamHost) -> Shown? {
        guard let daemon = host.cloudTeamMachines.first(where: { $0.vm == vm }) else { return nil }
        switch kind {
        case .workspace:
            return daemon.store.workspaces.first { $0.resourceID?.rawValue == id || $0.id == id }.map { .workspace($0.id) }
        case .chat:
            return daemon.store.liveTabs.first { $0.agentSession?.session == id }.map { .tab($0.id) }
        }
    }

    private func refuse(_ code: String, _ reason: String) -> ActionWorkFailure {
        registry?.refuse(reason)
        var failure = ActionWorkFailure(code: code, reason: reason)
        failure.shown = true
        return failure
    }
}
