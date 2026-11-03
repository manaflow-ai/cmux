import Darwin
import Foundation
import CMUXAgentLaunch

extension ClaudeHookSessionStore {
    private func activeSnapshot(
        _ record: ClaudeHookActiveSessionRecord
    ) -> ClaudeViewerActiveSessionSnapshot {
        ClaudeViewerActiveSessionSnapshot(
            sessionId: record.sessionId,
            turnId: record.turnId,
            allowsNewSessionReplacement: record.allowsNewSessionReplacement,
            updatedAt: record.updatedAt
        )
    }

    private func activeRecord(
        _ snapshot: ClaudeViewerActiveSessionSnapshot
    ) -> ClaudeHookActiveSessionRecord {
        ClaudeHookActiveSessionRecord(
            sessionId: snapshot.sessionId,
            turnId: snapshot.turnId,
            allowsNewSessionReplacement: snapshot.allowsNewSessionReplacement,
            updatedAt: snapshot.updatedAt
        )
    }

    /// Registers one acknowledged viewer and its ownership boundary in a single
    /// locked write. A dead viewer or worker leaves the store untouched.
    func registerClaudeViewer(
        sessionID: String,
        workspaceId: String,
        surfaceId: String,
        viewerPID: Int,
        viewer: ClaudeAttachedViewer
    ) throws -> Bool {
        // The observer bounds this call at 500 ms. A bounded lock makes
        // contention fail closed instead of blocking the hook indefinitely.
        try withLockedState(deadline: Date.now.addingTimeInterval(0.4)) { state in
            guard viewer.viewer.isAlive, viewer.worker.isAlive else { return false }
            let now = Date().timeIntervalSince1970
            var record = state.sessions[sessionID] ?? ClaudeHookSessionRecord(
                sessionId: sessionID,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                launchCommand: nil,
                isRestorable: nil,
                agentLifecycle: nil,
                lastSubtitle: nil,
                lastBody: nil,
                lastNotificationStatus: nil,
                lastEmittedNotificationFingerprint: nil,
                lastEmittedNotificationAt: nil,
                runtimeStatus: nil,
                activePromptDepth: nil,
                activePromptTurnId: nil,
                activePromptTurnIds: nil,
                lastPromptTurnId: nil,
                terminalPromptTurnIds: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            record.surfaceId = surfaceId
            record.updateProcessGeneration(
                pid: viewerPID,
                startIdentity: ClaudeViewerProcessIdentity(pid: viewerPID).map {
                    (Int64($0.seconds), Int64($0.microseconds))
                }
            )
            record.updatedAt = now
            // Capture the slots this admission replaces before overwriting
            // them. Detach restores them only while this session still owns
            // the slot, so a later owner is never overwritten.
            let displacedSurface = state.activeSessionsBySurface[surfaceId].map(activeSnapshot)
            let displacedWorkspace = state.activeSessionsByWorkspace[workspaceId].map(activeSnapshot)
            let stored = ClaudeAttachedViewer(
                attachmentID: viewer.attachmentID,
                worker: viewer.worker,
                viewer: viewer.viewer,
                socketPath: viewer.socketPath,
                workspaceID: workspaceId,
                surfaceID: surfaceId,
                attachedAt: viewer.attachedAt,
                displacedSurface: displacedSurface,
                displacedWorkspace: displacedWorkspace
            )
            record.claudeAttachedViewers = ClaudeViewerSubscriptions(record.claudeAttachedViewers ?? [])
                .adding(stored).viewers
            state.sessions[sessionID] = record
            // The launcher can have a different native session ID. Resolving
            // its viewer pane is not enough: Stop's existing staleness guard
            // must see the acknowledged conversation as that pane's owner.
            // Keep lease registration and this ownership boundary atomic.
            let active = ClaudeHookActiveSessionRecord(
                sessionId: sessionID, turnId: nil,
                allowsNewSessionReplacement: nil, updatedAt: viewer.attachedAt
            )
            state.activeSessionsBySurface[surfaceId] = active
            state.activeSessionsByWorkspace[workspaceId] = active
            return true
        }
    }

    /// Removes one lease and restores the slot it displaced only when this
    /// session still owns it and no other lease for the same pane remains.
    func removeClaudeViewer(attachmentID: String, viewerPID: Int, socketPath: String) throws {
        try withLockedState(deadline: Date.now.addingTimeInterval(0.4)) { state in
            for key in Array(state.sessions.keys) {
                guard var record = state.sessions[key],
                      let viewers = record.claudeAttachedViewers else { continue }
                let removed = viewers.filter {
                    $0.attachmentID == attachmentID && $0.viewer.pid == viewerPID
                        && $0.socketPath == socketPath
                }
                guard !removed.isEmpty else { continue }
                let remaining = ClaudeViewerSubscriptions(viewers)
                    .removing(attachmentID: attachmentID, viewerPID: viewerPID, socketPath: socketPath)
                    .viewers
                record.claudeAttachedViewers = remaining
                state.sessions[key] = record
                for lease in removed {
                    if !remaining.contains(where: { $0.surfaceID == lease.surfaceID }),
                       state.activeSessionsBySurface[lease.surfaceID]?.sessionId == key {
                        if let displaced = lease.displacedSurface {
                            state.activeSessionsBySurface[lease.surfaceID] = activeRecord(displaced)
                        } else {
                            state.activeSessionsBySurface.removeValue(forKey: lease.surfaceID)
                        }
                    }
                    if !remaining.contains(where: { $0.workspaceID == lease.workspaceID }),
                       state.activeSessionsByWorkspace[lease.workspaceID]?.sessionId == key {
                        if let displaced = lease.displacedWorkspace {
                            state.activeSessionsByWorkspace[lease.workspaceID] = activeRecord(displaced)
                        } else {
                            state.activeSessionsByWorkspace.removeValue(forKey: lease.workspaceID)
                        }
                    }
                }
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
        return try store.registerClaudeViewer(
            sessionID: sessionID,
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId,
            viewerPID: viewerPID,
            viewer: ClaudeAttachedViewer(
                attachmentID: attachmentID, worker: worker, viewer: viewerIdentity,
                socketPath: client.socketPath, workspaceID: target.workspaceId, surfaceID: target.surfaceId
            )
        )
    }

    /// Retains multiple subscriptions while preserving the existing single-target notification contract.
    func liveClaudeViewerTarget(
        sessionID: String, workerPID: Int, client: SocketClient
    ) throws -> AgentHookDeliveryTarget? {
        guard !client.isRelayBacked,
              let record = try ClaudeHookSessionStore().lookup(
                  sessionId: sessionID, deadline: Date.now.addingTimeInterval(0.4)) else { return nil }
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
