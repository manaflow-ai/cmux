import Foundation

/// Socket v2 surface for the Vault session index, so terminal agents can
/// browse, search, checkpoint, and fork sessions exactly like the UI
/// (`skills/cmux-shared-behavior`: same engines, no duplicated logic).
/// All commands run on the socket worker; `vault.fork` takes exactly one
/// `v2MainSync` hop when asked to open the forked session, and nothing here
/// activates the app or steals macOS focus.
extension TerminalController {
    private nonisolated static let vaultDeepListLimit = 500
    nonisolated static let vaultSessionsDefaultLimit = 30
    nonisolated static let vaultSessionsMaxLimit = 200

    // MARK: vault.sessions

    nonisolated func v2VaultSessions(params: [String: Any]) async -> V2CallResult {
        let agentFilter = Self.trimmedParam(params["agent"])
        let folderFilter = Self.trimmedParam(params["folder"])
        let requestedLimit = params["limit"] as? Int ?? Self.vaultSessionsDefaultLimit
        let limit = max(1, min(requestedLimit, Self.vaultSessionsMaxLimit))

        var entries = await SessionIndexStore.loadInitialEntries()
        if let agentFilter {
            entries = entries.filter { $0.agent.rawValue == agentFilter }
        }
        if let folderFilter {
            entries = entries.filter { ($0.cwd ?? "") == folderFilter }
        }
        let liveKeys = await Self.vaultLiveSessionKeys()
        let now = Date()
        return .ok([
            "sessions": entries.prefix(limit).map {
                Self.vaultSessionPayload($0, liveKeys: liveKeys, now: now)
            },
        ])
    }

    // MARK: vault.search

    nonisolated func v2VaultSearch(params: [String: Any]) async -> V2CallResult {
        guard let query = Self.trimmedParam(params["query"]) else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.vault.missingQuery",
                                defaultValue: "query is required."),
                data: nil
            )
        }
        let requestedLimit = params["limit"] as? Int ?? Self.vaultSessionsDefaultLimit
        let limit = max(1, min(requestedLimit, Self.vaultSessionsMaxLimit))
        let entries = await SessionIndexStore.loadInitialEntries()
        let outcome = await SessionIndexStore.searchAllSessions(
            rawQuery: query,
            entries: entries,
            scopedDirectory: nil
        )
        let liveKeys = await Self.vaultLiveSessionKeys()
        let now = Date()
        return .ok([
            "query": query,
            "errors": outcome.errors,
            "sessions": outcome.entries.prefix(limit).map {
                Self.vaultSessionPayload($0, liveKeys: liveKeys, now: now)
            },
        ])
    }

    // MARK: vault.checkpoints

    nonisolated func v2VaultCheckpoints(params: [String: Any]) async -> V2CallResult {
        switch await Self.vaultResolveEntry(params: params) {
        case .failure(let error):
            return error
        case .success(let entry):
            let derived = await VaultCheckpointHarness.derive(for: entry)
            let manual = await VaultSessionCheckpointStore.shared.checkpoints(
                agentID: entry.agent.rawValue,
                sessionID: entry.sessionId
            )
            let merged = ((derived?.checkpoints ?? []) + manual).sorted {
                ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }
            return .ok([
                "agent": entry.agent.rawValue,
                "session_id": entry.sessionId,
                "supports_fork": VaultCheckpointHarness.resolve(for: entry)?.supportsFork ?? false,
                "truncated": derived?.isTruncated ?? false,
                "checkpoints": merged.map(Self.vaultCheckpointPayload),
            ])
        }
    }

    // MARK: vault.checkpoint (create manual)

    nonisolated func v2VaultCheckpointCreate(params: [String: Any]) async -> V2CallResult {
        switch await Self.vaultResolveEntry(params: params) {
        case .failure(let error):
            return error
        case .success(let entry):
            let name = Self.trimmedParam(params["name"])
            guard let derivation = await VaultCheckpointHarness.derive(for: entry) else {
                return .err(
                    code: "not_supported",
                    message: String(localized: "socket.vault.noTranscript",
                                    defaultValue: "This session has no readable transcript."),
                    data: nil
                )
            }
            let sha = entry.cwd.flatMap { cwd -> String? in
                guard !cwd.isEmpty else { return nil }
                return VaultGitHeadReader.headSHA(workspacePath: cwd)
            }
            let checkpoint = VaultSessionCheckpoint(
                id: "manual:" + UUID().uuidString.lowercased(),
                source: .manual,
                timestamp: Date(),
                name: name,
                turnIndex: derivation.checkpoints.count,
                anchor: derivation.lastAnchor,
                gitSHA: sha,
                promptSnippet: derivation.checkpoints.last?.promptSnippet
            )
            do {
                _ = try await VaultSessionCheckpointStore.shared.append(
                    checkpoint,
                    agentID: entry.agent.rawValue,
                    sessionID: entry.sessionId
                )
            } catch {
                return .err(
                    code: "write_failed",
                    message: String(localized: "sessionIndex.checkpoints.saveFailed",
                                    defaultValue: "Couldn't save checkpoint"),
                    data: nil
                )
            }
            return .ok(["checkpoint": Self.vaultCheckpointPayload(checkpoint)])
        }
    }

    // MARK: vault.fork

    nonisolated func v2VaultFork(params: [String: Any]) async -> V2CallResult {
        switch await Self.vaultResolveEntry(params: params) {
        case .failure(let error):
            return error
        case .success(let entry):
            let derived = await VaultCheckpointHarness.derive(for: entry)
            let manual = await VaultSessionCheckpointStore.shared.checkpoints(
                agentID: entry.agent.rawValue,
                sessionID: entry.sessionId
            )
            let all = (derived?.checkpoints ?? []) + manual

            let checkpoint: VaultSessionCheckpoint?
            if let checkpointID = Self.trimmedParam(params["checkpoint"]) {
                checkpoint = all.first { $0.id == checkpointID }
            } else if let turn = params["turn"] as? Int {
                checkpoint = all.first { $0.source == .turn && $0.turnIndex == turn }
            } else {
                checkpoint = nil
            }
            guard let checkpoint else {
                return .err(
                    code: "not_found",
                    message: String(localized: "socket.vault.checkpointNotFound",
                                    defaultValue: "No checkpoint matched. Pass checkpoint <id> or turn <n> from vault checkpoints."),
                    data: nil
                )
            }

            let newSessionID = UUID().uuidString.lowercased()
            let forkedURL: URL
            do {
                forkedURL = try VaultCheckpointHarness.fork(
                    entry: entry,
                    checkpoint: checkpoint,
                    newSessionID: newSessionID
                )
            } catch let error as VaultCheckpointForkError {
                return .err(code: "fork_failed", message: error.localizedSummary, data: nil)
            } catch {
                return .err(
                    code: "fork_failed",
                    message: String(localized: "sessionIndex.checkpoints.error.unknown",
                                    defaultValue: "An unexpected error occurred"),
                    data: nil
                )
            }

            let forked = entry.forkedEntry(newSessionID: newSessionID, fileURL: forkedURL, now: Date())
            var opened = false
            if params["open"] as? Bool == true {
                opened = v2MainSync(commandKey: "vault.fork") {
                    MainActor.assumeIsolated {
                        guard let tabManager = self.tabManager else { return false }
                        SessionEntryResumeCoordinator.resume(forked, tabManager: tabManager)
                        return true
                    }
                }
            }
            var payload: [String: Any] = [
                "agent": forked.agent.rawValue,
                "session_id": newSessionID,
                "parent_session_id": entry.sessionId,
                "file": forkedURL.path,
                "cwd": forked.cwd as Any,
                "opened": opened,
            ]
            if let resumeCommand = forked.copyResumeCommand {
                payload["resume_command"] = resumeCommand
            }
            return .ok(payload)
        }
    }

    // MARK: Shared helpers

    private nonisolated enum VaultEntryResolution {
        case success(SessionEntry)
        case failure(V2CallResult)
    }

    /// Resolves (agent, session_id) against the index: the fast top-N scan
    /// first, then one deeper bounded per-agent listing. The transcript path
    /// always comes from the index, never from the caller — a caller-supplied
    /// path would be an arbitrary-file primitive.
    private nonisolated static func vaultResolveEntry(params: [String: Any]) async -> VaultEntryResolution {
        guard let agentID = trimmedParam(params["agent"]),
              let sessionID = trimmedParam(params["session"]) else {
            return .failure(.err(
                code: "invalid_params",
                message: String(localized: "socket.vault.missingSessionSelector",
                                defaultValue: "agent and session are required."),
                data: nil
            ))
        }
        let quick = await SessionIndexStore.loadInitialEntries()
        if let entry = quick.first(where: { $0.agent.rawValue == agentID && $0.sessionId == sessionID }) {
            return .success(entry)
        }
        guard let agent = SessionAgent(rawValue: agentID) else {
            return .failure(.err(
                code: "not_found",
                message: String(localized: "socket.vault.unknownAgent",
                                defaultValue: "Unknown agent."),
                data: nil
            ))
        }
        let registry = await SessionIndexStore.vaultAgentRegistry(workingDirectory: nil)
        let deep = await SessionIndexStore.searchAgent(
            needle: "",
            agent: agent,
            cwdFilter: nil,
            offset: 0,
            limit: vaultDeepListLimit,
            errorBag: SessionIndexStore.ErrorBag(),
            registry: registry
        )
        if let entry = deep.first(where: { $0.sessionId == sessionID }) {
            return .success(entry)
        }
        return .failure(.err(
            code: "not_found",
            message: String(localized: "socket.vault.sessionNotFound",
                            defaultValue: "No Vault session matched."),
            data: nil
        ))
    }

    nonisolated static func vaultLiveSessionKeys() async -> Set<String> {
        let index = await MainActor.run {
            SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
        }
        return VaultLiveSessionKeys.runningKeys(in: index)
    }

    nonisolated static func vaultSessionPayload(
        _ entry: SessionEntry,
        liveKeys: Set<String>,
        now: Date
    ) -> [String: Any] {
        let status = VaultSessionLiveStatus.derive(
            isProcessRunning: liveKeys.contains(VaultLiveSessionKeys.key(for: entry)),
            lastActivity: entry.modified,
            now: now
        )
        var payload: [String: Any] = [
            "agent": entry.agent.rawValue,
            "session_id": entry.sessionId,
            "title": entry.displayTitle,
            "modified": entry.modified.formatted(.iso8601),
            "status": String(describing: status),
        ]
        if let cwd = entry.cwd, !cwd.isEmpty { payload["cwd"] = cwd }
        if let branch = entry.gitBranch, !branch.isEmpty { payload["git_branch"] = branch }
        if let created = entry.created { payload["created"] = created.formatted(.iso8601) }
        if let count = entry.messageCount { payload["message_count"] = count }
        if let file = entry.fileURL?.path { payload["file"] = file }
        if let resume = entry.copyResumeCommand { payload["resume_command"] = resume }
        return payload
    }

    nonisolated static func vaultCheckpointPayload(_ checkpoint: VaultSessionCheckpoint) -> [String: Any] {
        var payload: [String: Any] = [
            "id": checkpoint.id,
            "source": checkpoint.source.rawValue,
            "turn": checkpoint.turnIndex,
        ]
        if let timestamp = checkpoint.timestamp { payload["timestamp"] = timestamp.formatted(.iso8601) }
        if let name = checkpoint.name { payload["name"] = name }
        if let anchor = checkpoint.anchor { payload["anchor"] = anchor }
        if let sha = checkpoint.gitSHA { payload["git_sha"] = sha }
        if let snippet = checkpoint.promptSnippet { payload["prompt"] = snippet }
        return payload
    }

    private nonisolated static func trimmedParam(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }
}
