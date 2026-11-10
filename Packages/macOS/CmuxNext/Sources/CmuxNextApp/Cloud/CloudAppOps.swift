import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

extension CloudAppLinks {
    /// Runs Cloud app ops on `local`'s current connection. A refusal is a
    /// ``CloudAppOpFailure``; origin `user` is sent only where the daemon
    /// allows it (the verified app connection), never upgraded here.
    static func ops(local: DaemonService) -> CloudAppOp {
        let timeout: Duration = .seconds(120) // a start waits for a paused machine
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudAppOpFailure(code: "cmux.cloud.relay_unavailable", message: DaemonError.notConnected.description)
            }
            let allowed = await connection.userOriginAllowed
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: args, idempotencyKey: key,
                                         origin: origin == .user && allowed ? .user : .script)
            do {
                return try await connection.request(request, timeout: timeout).value
            } catch DaemonError.command(_, let message, let code, let details, _) {
                throw CloudAppOpFailure(code: code ?? "", message: message, details: details)
            }
        }
    }
}

/// The child chat opener the transcript fork leaves for the last step: the child machine's pane and
/// daemon are only known once the fork has found the restored parent there.
@MainActor
private final class CloudTryAnotherApproachChildOpener {
    var open: (@MainActor (CloudTryAnotherApproach.Plan, String) async throws -> String)?
}

private func cloudTryAnotherApproachFailure(_ message: String) -> NSError {
    NSError(domain: "cloud.tryAnotherApproach", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Signed-in Cloud chat `chat` showing `session`: its workspace (the platform's workspace id) and the
/// Cloud machine it runs on, or nil.
@MainActor
private func cloudChatPlace(chat: String, session expected: String, services: AppServices)
    -> (workspace: String, workspaceName: String, machine: String, harness: String?)? {
    guard services.cloud.auth.isSignedIn,
          let (tab, pane) = services.locateTab(chat),
          let record = tab.agentSession, record.session == expected else { return nil }
    let daemon = services.machines.daemon(forTab: tab)
    guard let cloud = services.machines.session(daemon.machineID),
          let workspace = services.machines.allWorkspaces.first(where: { workspace, owner in
              owner === daemon && workspace.screens.flatMap(\.panes).contains { $0 === pane }
          })?.0 else { return nil }
    return (workspace.id, workspace.displayName, cloud.machineID, record.harness)
}

/// Whether Cloud chats offer turn checkpoints: signed in and `cloud.turnCheckpoints` on (off by default).
@MainActor
func cloudTurnRewindIsOn(_ services: AppServices) -> Bool {
    services.cloud.auth.isSignedIn
        && CloudNewWorkspaceSetting().turnCheckpoints(in: services.settings?.snapshot.root ?? .object([:]))
}

/// A Cloud chat's turn checkpoint or rewind. Swift only because the person's Cloud token lives in
/// the app's Keychain: the sequence is cmux-cloud-api's (`owner.turn_checkpoint`, `owner.turn_rewind`).
@MainActor
func runCloudTurnRewind(chat key: String, session: String, request: AgentPaneCloudTurnRewind,
                        services: AppServices) async throws -> [String: Any] {
    guard cloudTurnRewindIsOn(services), let place = cloudChatPlace(chat: key, session: session, services: services),
          let connection = services.machines.local.connection else {
        throw NSError(domain: "cloud.turnRewind", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cloud chat is unavailable"])
    }
    let team = (try? await services.cloud.installIdentity.installToken()).flatMap(MacInstallIdentity.team(ofToken:))
    let credential = CloudTurnRewindClient.Credential(api: FeedService.apiBaseURL(auth: services.cloud.auth).absoluteString,
                                                      accessToken: try await services.cloud.auth.tokens().access, team: team)
    let client = CloudTurnRewindClient(connection: connection)
    // The platform keys a checkpoint by workspace, session and turn, so the turn names its key; a
    // rewind is a new one each click (the same key would answer the first rewind again).
    let answer: CmuxNextDaemon.JSONValue
    switch request {
    case .checkpoint:
        answer = try await client.checkpoint(credential, workspace: place.workspace, carrierMachine: place.machine,
                                             session: session, turnSeq: request.turnSeq, clientKey: "cmux-turn-\(request.turnSeq)")
    case .rewind:
        answer = try await client.rewind(credential, workspace: place.workspace, session: session, turnSeq: request.turnSeq,
                                         clientKey: "cmux-rewind-\(request.turnSeq)-\(UUID().uuidString.prefix(8))")
    }
    return (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))) as? [String: Any] ?? [:]
}

/// App adapters for the latest-turn Cloud fork. The sequence itself lives in CmuxNextCloud.
@MainActor
func cloudTryAnotherApproach(chat key: String, session expected: String, throughSeq: Int, services: AppServices) async throws -> [String: Any] {
    let opener = CloudTryAnotherApproachChildOpener()
    let fork = CloudTryAnotherApproach(
        prepare: { chat, seq in
            guard seq > 0, let place = cloudChatPlace(chat: chat, session: expected, services: services),
                  let harness = place.harness else {
                throw cloudTryAnotherApproachFailure("Cloud chat is unavailable")
            }
            return .init(workspace: place.workspace, sourceMachine: place.machine, session: expected,
                         harness: harness, throughSeq: seq,
                         clientKey: "cmux-next-try-another-approach-\(chat)-\(expected)-\(seq)",
                         parentLabel: "Try another approach · \(place.workspaceName)")
        },
        forkMachine: { plan in
            let owner = CloudOwnerAPIClient(
                baseURL: FeedService.apiBaseURL(auth: services.cloud.auth), accessToken: { try await services.cloud.auth.tokens().access },
                teamID: { [identity = services.cloud.installIdentity] in (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) })
            let children = try await owner.forkRun(workspace: plan.workspace, clientKey: plan.clientKey,
                                                   sourceMachine: plan.sourceMachine, session: plan.session,
                                                   harnesses: [plan.harness])
            guard let child = children.first else { throw cloudTryAnotherApproachFailure("Cloud did not return a child") }
            return child
        },
        forkTranscript: { plan, childMachine in
            let ready = await CloudWait.holds(tries: 60, each: .seconds(3),
                                              redial: { await services.cloud.refresh(ifOlderThan: .zero) }) { [services] in
                guard let session = services.machines.session(childMachine) else { return false }
                return session.daemon.connection != nil
                    && session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                        .contains { $0.agentSession?.session == plan.session }
            }
            guard ready else { throw cloudTryAnotherApproachFailure("Child machine did not connect") }
            guard let childSession = services.machines.session(childMachine) else {
                throw cloudTryAnotherApproachFailure("Child machine is not connected")
            }
            let daemon = childSession.daemon
            guard let parentTab = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first(where: { $0.agentSession?.session == plan.session }),
                  let pane = daemon.store.pane(holding: parentTab) else {
                throw cloudTryAnotherApproachFailure("Child machine did not restore the parent chat")
            }
            let attach = AgentSessionAttachClient(surface: parentTab.surface.rawValue,
                                                   endpoint: { try await daemon.endpoint() })
            do {
                _ = try await attach.attach(afterSeq: nil, beforeSeq: nil, limit: 1, kinds: nil) { _, _ in }
                let forked = try await attach.fork(throughSeq: plan.throughSeq, name: plan.parentLabel)
                _ = try await attach.children()
                await attach.close()
                RemoteAgentSessionLinks.shared.noteFork(forked.session, parent: plan.session,
                                                        host: AgentTabStore.registryHost(of: daemon))
                opener.open = { plan, session in
                    let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session,
                                                              idempotencyKey: plan.clientKey)
                    return try await pending.value().key
                }
                return forked.session
            } catch {
                await attach.close()
                throw error
            }
        },
        openChild: { plan, _, session in
            guard let open = opener.open else { throw cloudTryAnotherApproachFailure("Child chat is unavailable") }
            return try await open(plan, session)
        })
    let result = try await fork.run(chat: key, throughSeq: throughSeq)
    return ["childMachine": result.childMachine, "childSession": result.childSession, "childTab": result.childTab,
            "parentLabel": result.parentLabel, "throughSeq": result.throughSeq]
}
