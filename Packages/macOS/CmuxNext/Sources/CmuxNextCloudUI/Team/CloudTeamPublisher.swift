import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Tells the person's team about their Cloud chats (lane D): each chat tab on one of their Cloud
/// machines is published to TeamDO (`team.cloud.session.publish`) when it starts and whenever its
/// title, activity (working, needs attention, idle) or its machine's state changes. It follows the
/// Cloud machines' stores through one ``ObservationStream`` (no timer; an equal value wakes
/// nothing) and sends only what changed (``CloudTeamPublishPlan``). Teammates' machines are never
/// here (CloudMachineShare refuses them), so everything it publishes is the person's own.
@MainActor
final class CloudTeamPublisher {
    private weak var host: (any CloudTeamHost)?
    private let store: CloudTeamSessionStore
    private var plan = CloudTeamPublishPlan()
    private var account: [String?] = []
    private var watching: Task<Void, Never>?

    init(host: any CloudTeamHost, store: CloudTeamSessionStore) {
        self.host = host
        self.store = store
    }

    /// Starts following the Cloud chats (once).
    func start() {
        guard watching == nil else { return }
        // task-owner: the publisher's one observation of the Cloud chats; it lives with the app.
        watching = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.inputs() ?? [] }) {
                self?.flush()
            }
        }
    }

    /// Sends every chat whose published state changed (also right after a chat starts).
    func flush() {
        guard let host, host.cloudTeamSignedIn, host.cloudTeamID != nil else { return plan.reset() }
        let now = [host.cloudTeamUserID, host.cloudTeamID]
        if now != account {
            account = now
            plan.reset()
        }
        let store = store
        for (input, at) in plan.changes(inputs(), now: Int(Date().timeIntervalSince1970 * 1000)) {
            // task-owner: one publish; a refused one is sent again on the chat's next change.
            Task { [weak self] in
                do {
                    _ = try await store.publish(input.ref, title: input.title, workspace: input.workspace, harness: input.harness,
                                                machineState: input.machineState, activity: input.activity, lastActivityAt: at)
                } catch {
                    self?.plan.forget(input.ref.key)
                }
            }
        }
    }

    /// Every chat tab with a session on the person's Cloud machines, as it would be published now.
    func inputs() -> [CloudTeamPublishInput] {
        guard let host, let team = host.cloudTeamID else { return [] }
        var out: [CloudTeamPublishInput] = []
        // Only ids TeamDO takes (CloudSessionVm, CloudSessionId): another one would be refused on every change.
        for machine in host.cloudTeamMachines where DeepLink.isCloudVM(machine.vm) {
            let store = machine.store
            let connected = if case .connected = store.connectionState { true } else { false }
            let state = CloudTeamPublishInput.machineState(status: machine.status, connected: connected)
            for tab in store.liveTabs {
                guard let agent = tab.agentSession, let session = agent.session, DeepLink.isCloudSessionID(session) else { continue }
                let workspace = store.pane(holding: tab).flatMap { store.location(of: $0)?.workspace }
                    .map { $0.resourceID?.rawValue ?? $0.id }.flatMap { DeepLink.isCloudSessionID($0) ? $0 : nil }
                out.append(CloudTeamPublishInput(
                    ref: .init(team: team, vm: machine.vm, session: session, kind: .chat), title: tab.displayTitle,
                    workspace: workspace, harness: agent.harness, machineState: state,
                    activity: CloudTeamPublishInput.activity(agentState: tab.agent.map(\.state.rawValue), attention: tab.attention != nil)))
            }
        }
        return out
    }
}
