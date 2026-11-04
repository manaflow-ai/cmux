import CmuxNextAgentPane
import CmuxNextCloud
import Foundation

/// Forks a Cloud chat at its latest completed turn. ForkRuns snapshots the machine first;
/// the child daemon then asks acpmux to copy that chat through the same turn.
@MainActor
enum CloudTryAnotherApproach {
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "cloud.tryAnotherApproach", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func run(chat key: String, throughSeq: Int, services: AppServices) async throws -> [String: Any] {
        guard throughSeq > 0, services.cloud.auth.isSignedIn,
              let (sourceTab, sourcePane) = services.locateTab(key),
              let sourceRecord = sourceTab.agentSession,
              let sourceSession = sourceRecord.session,
              let harness = sourceRecord.harness,
              let sourceDaemon = services.machines.daemon(forTab: sourceTab),
              let sourceCloud = services.machines.session(sourceDaemon.machineID),
              let workspace = services.machines.allWorkspaces.first(where: { workspace, daemon in
                  daemon === sourceDaemon && workspace.screens.flatMap(\.panes).contains { $0 === sourcePane }
              })?.0 else {
            throw failure("Cloud chat is unavailable")
        }

        let clientKey = "cmux-next-try-another-approach-\(key)-\(sourceSession)-\(throughSeq)"
        let owner = CloudOwnerAPIClient(
            baseURL: FeedService.apiBaseURL(auth: services.cloud.auth),
            accessToken: { try await services.cloud.auth.tokens().access },
            teamID: { nil })
        let children = try await owner.forkRun(
            workspace: workspace.id,
            clientKey: clientKey,
            sourceMachine: sourceCloud.machineID,
            session: sourceSession,
            harnesses: [harness])
        guard let childMachine = children.first?.machineId else {
            throw failure("Cloud did not return a child machine")
        }

        await services.cloud.refresh(ifOlderThan: .zero)
        guard let childSession = services.machines.session(childMachine) else {
            throw failure("Child machine is not connected")
        }
        let childDaemon = childSession.daemon
        guard let parentTab = childDaemon.store.workspaces
                .flatMap(\.screens)
                .flatMap(\.panes)
                .flatMap(\.tabs)
                .first(where: { $0.agentSession?.session == sourceSession }),
              let parentPane = childDaemon.store.pane(holding: parentTab) else {
            throw failure("Child machine did not restore the parent chat")
        }

        let parentLabel = "Try another approach · \(workspace.displayName)"
        let attach = AgentSessionAttachClient(
            surface: parentTab.surface.rawValue,
            endpoint: { try await childDaemon.endpoint() })
        let forked: (session: String, data: Data)
        do {
            forked = try await attach.fork(throughSeq: throughSeq, name: parentLabel)
        } catch {
            await attach.close()
            throw error
        }
        await attach.close()

        // The remote-child admission path requires a trusted parent link before the tab is opened.
        RemoteAgentSessionLinks.shared.noteFork(forked.session, parent: sourceSession)
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(
                in: parentPane.handle,
                of: childDaemon,
                session: forked.session,
                idempotencyKey: clientKey)
        } catch {
            throw error
        }
        let created = try await pending.value()
        return [
            "childMachine": childMachine,
            "childSession": forked.session,
            "childTab": created.key,
            "parentLabel": parentLabel,
            "throughSeq": throughSeq,
        ]
    }
}
