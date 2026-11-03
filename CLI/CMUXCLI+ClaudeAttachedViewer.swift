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
            // Capture the pre-attach route and the earliest pane slots before
            // this admission overwrites them. The first admission on a pane
            // owns the snapshot that a later last-detach must restore; later
            // admissions on the same pane must not replace it with the
            // worker's own slot.
            let hadViewers = !(record.claudeAttachedViewers ?? []).isEmpty
            if state.sessions[sessionID] != nil, !hadViewers {
                record.claudeViewerOriginalRoute = ClaudeViewerOriginalRoute(
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    pid: record.pid,
                    pidStartSeconds: record.pidStartSeconds,
                    pidStartMicroseconds: record.pidStartMicroseconds
                )
            }
            if record.claudeViewerOriginalSurfaceSlots == nil {
                record.claudeViewerOriginalSurfaceSlots = [:]
            }
            if record.claudeViewerOriginalWorkspaceSlots == nil {
                record.claudeViewerOriginalWorkspaceSlots = [:]
            }
            if record.claudeViewerOriginalSurfaceSlots?[surfaceId] == nil,
               let slot = state.activeSessionsBySurface[surfaceId] {
                record.claudeViewerOriginalSurfaceSlots?[surfaceId] = activeSnapshot(slot)
            }
            if record.claudeViewerOriginalWorkspaceSlots?[workspaceId] == nil,
               let slot = state.activeSessionsByWorkspace[workspaceId] {
                record.claudeViewerOriginalWorkspaceSlots?[workspaceId] = activeSnapshot(slot)
            }
            record.claudeViewerRouteSurfaceId = surfaceId
            record.workspaceId = workspaceId
            record.surfaceId = surfaceId
            record.updateProcessGeneration(
                pid: viewerPID,
                startIdentity: ClaudeViewerProcessIdentity(pid: viewerPID).map {
                    (Int64($0.seconds), Int64($0.microseconds))
                }
            )
            record.updatedAt = now
            // Keep the per-lease snapshot for older records; the record-level
            // per-pane map above is authoritative for restoration.
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
    @discardableResult
    func removeClaudeViewer(attachmentID: String, viewerPID: Int, socketPath: String) throws -> Bool {
        try withLockedState(deadline: Date.now.addingTimeInterval(0.4)) { state in
            var didRemove = false
            for key in Array(state.sessions.keys) {
                guard var record = state.sessions[key],
                      let viewers = record.claudeAttachedViewers else { continue }
                let removed = viewers.filter {
                    $0.attachmentID == attachmentID && $0.viewer.pid == viewerPID
                        && $0.socketPath == socketPath
                }
                guard !removed.isEmpty else { continue }
                didRemove = true
                let remaining = ClaudeViewerSubscriptions(viewers)
                    .removing(attachmentID: attachmentID, viewerPID: viewerPID, socketPath: socketPath)
                    .viewers
                record.claudeAttachedViewers = remaining
                for lease in removed {
                    if !remaining.contains(where: { $0.surfaceID == lease.surfaceID }),
                       state.activeSessionsBySurface[lease.surfaceID]?.sessionId == key {
                        if let earliest = record.claudeViewerOriginalSurfaceSlots?[lease.surfaceID] {
                            state.activeSessionsBySurface[lease.surfaceID] = activeRecord(earliest)
                        } else {
                            state.activeSessionsBySurface.removeValue(forKey: lease.surfaceID)
                        }
                        record.claudeViewerOriginalSurfaceSlots?.removeValue(forKey: lease.surfaceID)
                    }
                    if !remaining.contains(where: { $0.workspaceID == lease.workspaceID }),
                       state.activeSessionsByWorkspace[lease.workspaceID]?.sessionId == key {
                        if let earliest = record.claudeViewerOriginalWorkspaceSlots?[lease.workspaceID] {
                            state.activeSessionsByWorkspace[lease.workspaceID] = activeRecord(earliest)
                        } else {
                            state.activeSessionsByWorkspace.removeValue(forKey: lease.workspaceID)
                        }
                        record.claudeViewerOriginalWorkspaceSlots?.removeValue(forKey: lease.workspaceID)
                    }
                }
                if remaining.isEmpty {
                    // Restore the worker's own route only while the record
                    // still points at the viewer route this session wrote.
                    if let original = record.claudeViewerOriginalRoute,
                       let viewerSurface = record.claudeViewerRouteSurfaceId,
                       record.surfaceId.caseInsensitiveCompare(viewerSurface) == .orderedSame {
                        record.workspaceId = original.workspaceId
                        record.surfaceId = original.surfaceId
                        if let pid = original.pid {
                            record.updateProcessGeneration(
                                pid: pid,
                                startIdentity: original.pidStartSeconds.flatMap { seconds in
                                    original.pidStartMicroseconds.map { (seconds, $0) }
                                }
                            )
                        }
                    }
                    record.claudeViewerOriginalRoute = nil
                    record.claudeViewerRouteSurfaceId = nil
                    record.claudeViewerOriginalSurfaceSlots = nil
                    record.claudeViewerOriginalWorkspaceSlots = nil
                }
                state.sessions[key] = record
            }
            return didRemove
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
            // Exit non-zero when no lease matched so the observer retries until
            // the removal is confirmed. A lock failure throws for the same
            // retry path.
            let removed = try store.removeClaudeViewer(
                attachmentID: attachmentID, viewerPID: viewerPID, socketPath: client.socketPath)
            if removed { removeClaudeViewerClosedMarker(attachmentID) }
            return removed
        }
        guard !claudeViewerClosedMarkerExists(attachmentID) else { return false }
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

    /// The authoritative tombstone written by the connection owner when the
    /// native attach socket closes. It remains usable when the detach CLI call
    /// fails or no later event arrives.
    func claudeViewerClosedMarkerPath(
        _ attachmentID: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let statePath: String
        if let override = env["CMUX_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            statePath = NSString(string: override).expandingTildeInPath
        } else if let directory = env["CMUX_AGENT_HOOK_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !directory.isEmpty {
            statePath = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json").path
        } else {
            statePath = NSString(string: "~/.cmuxterm/claude-hook-sessions.json").expandingTildeInPath
        }
        return URL(fileURLWithPath: statePath)
            .deletingLastPathComponent()
            .appendingPathComponent("claude-viewer-closed", isDirectory: true)
            .appendingPathComponent(attachmentID.lowercased(), isDirectory: false)
            .path
    }

    func claudeViewerClosedMarkerExists(_ attachmentID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: claudeViewerClosedMarkerPath(attachmentID)
        )
    }

    func removeClaudeViewerClosedMarker(_ attachmentID: String) {
        try? FileManager.default.removeItem(
            atPath: claudeViewerClosedMarkerPath(attachmentID)
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
        for viewer in viewers where !claudeViewerClosedMarkerExists(viewer.attachmentID) {
            guard let target = admittedAgentHookRoute(processID: viewer.viewer.pid, client: client, socketPassword: nil),
                  target.surfaceId == viewer.surfaceID else { continue }
            // A pane can move workspaces without changing its stable surface.
            return AgentHookDeliveryTarget(workspaceId: target.workspaceId, surfaceId: target.surfaceId, isAuthoritative: true)
        }
        return nil
    }
}
