import Darwin
import Foundation
import CMUXAgentLaunch

extension ClaudeHookSessionStore {
    func addClaudeViewer(sessionID: String, viewer: ClaudeAttachedViewer) throws -> Bool {
        try withLockedState { state in
            guard viewer.viewer.isAlive, viewer.worker.isAlive,
                  var record = state.sessions[sessionID] else { return false }
            record.claudeAttachedViewers = ClaudeViewerSubscriptions(record.claudeAttachedViewers ?? [])
                .adding(viewer).viewers
            state.sessions[sessionID] = record
            // The launcher can have a different native session ID. Resolving
            // its viewer pane is not enough: Stop's existing staleness guard
            // must see the acknowledged conversation as that pane's owner.
            // Keep lease registration and this ownership boundary atomic.
            let active = ClaudeHookActiveSessionRecord(
                sessionId: sessionID, turnId: nil,
                allowsNewSessionReplacement: nil, updatedAt: viewer.attachedAt
            )
            state.activeSessionsBySurface[viewer.surfaceID] = active
            state.activeSessionsByWorkspace[viewer.workspaceID] = active
            return true
        }
    }

    func removeClaudeViewer(attachmentID: String, viewerPID: Int, socketPath: String) throws {
        try withLockedState { state in
            for key in Array(state.sessions.keys) {
                guard var record = state.sessions[key], let viewers = record.claudeAttachedViewers else { continue }
                record.claudeAttachedViewers = ClaudeViewerSubscriptions(viewers)
                    .removing(attachmentID: attachmentID, viewerPID: viewerPID, socketPath: socketPath).viewers
                state.sessions[key] = record
            }
        }
    }
}

extension CMUXCLI {
    /// Internal sink for acknowledged native attach connections. No transcript/authentication input.
    func runClaudeViewerHook(commandArgs: [String], client: SocketClient) throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard !client.isRelayBacked, env[agentHookRelayOriginEnvironmentKey] != "1",
              let input = try? JSONSerialization.jsonObject(
                with: FileHandle.standardInput.readData(ofLength: 16_385)
              ) as? [String: Any],
              let id = input["attach_id"] as? String, let attachment = UUID(uuidString: id),
              let viewerPID = (input["viewer_pid"] as? NSNumber)?.intValue,
              viewerPID == Int(getppid()),
              let viewerIdentity = ClaudeViewerProcessIdentity(pid: viewerPID) else { return false }
        let store = ClaudeHookSessionStore()
        let attachmentID = attachment.uuidString.lowercased()
        if commandArgs.first == "detached" {
            try store.removeClaudeViewer(attachmentID: attachmentID, viewerPID: viewerPID, socketPath: client.socketPath)
            return true
        }
        guard commandArgs.first == "attached",
              let reference = input["job_id"] as? String,
              let registration = ClaudeBackgroundSessionRegistry(
                configDirectory: ClaudeBackgroundSessionRegistry.configDirectory(environment: env)
              ).liveBackgroundSession(matching: reference),
              let sessionID = UUID(uuidString: registration.sessionID)?.uuidString.lowercased(),
              let worker = ClaudeViewerProcessIdentity(pid: registration.processID),
              case .resolved(let target) = liveAgentPidDeliveryTarget(pid: viewerPID, client: client),
              target.isAuthoritative else { return false }
        _ = try store.upsert(
            sessionId: sessionID, workspaceId: target.workspaceId, surfaceId: target.surfaceId,
            cwd: nil, pid: viewerPID
        )
        return try store.addClaudeViewer(sessionID: sessionID, viewer: ClaudeAttachedViewer(
            attachmentID: attachmentID, worker: worker, viewer: viewerIdentity,
            socketPath: client.socketPath, workspaceID: target.workspaceId, surfaceID: target.surfaceId
        ))
    }

    /// Retains multiple subscriptions while preserving the existing single-target notification contract.
    func liveClaudeViewerTarget(
        sessionID: String, workerPID: Int, client: SocketClient
    ) throws -> AgentHookDeliveryTarget? {
        guard !client.isRelayBacked,
              let record = try ClaudeHookSessionStore().lookup(sessionId: sessionID) else { return nil }
        let viewers = ClaudeViewerSubscriptions(record.claudeAttachedViewers ?? [])
            .candidates(workerPID: workerPID, socketPath: client.socketPath)
        for viewer in viewers {
            guard let target = admittedAgentHookRoute(processID: viewer.viewer.pid, client: client, socketPassword: nil),
                  target.surfaceId == viewer.surfaceID else { continue }
            // A pane can move workspaces without changing its stable surface.
            return AgentHookDeliveryTarget(workspaceId: target.workspaceId, surfaceId: target.surfaceId, isAuthoritative: true)
        }
        return nil
    }
}
