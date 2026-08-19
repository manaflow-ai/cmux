import Foundation

/// Per-harness checkpoint capability for a Vault session: how turn
/// checkpoints derive from its transcript and, where the on-disk format
/// allows, how a truncated fork copy is produced. Harnesses whose sessions
/// live in databases (OpenCode, Rovo Dev, Hermes, Antigravity) get a derived
/// timeline but no checkpoint fork — same-harness file forking only
/// (cross-harness is issue #9016).
enum VaultCheckpointHarness: Equatable, Sendable {
    case claude
    case codex
    case grok
    /// pi / omp / campfire: `<ts>_<uuid>.jsonl` files with per-line ids.
    case piFamily
    /// Transcript is readable (via `SessionTranscriptLoader`) but there is no
    /// file the fork copy could anchor into.
    case timelineOnly

    /// Registered-agent ids that share pi's session file format.
    nonisolated static let piFamilyIDs: Set<String> = ["pi", "omp", "campfire"]

    nonisolated static func resolve(for entry: SessionEntry) -> VaultCheckpointHarness? {
        switch entry.agent {
        case .claude:
            return entry.fileURL != nil ? .claude : .timelineOnly
        case .codex:
            return entry.fileURL != nil ? .codex : .timelineOnly
        case .grok:
            return entry.fileURL != nil ? .grok : .timelineOnly
        case .opencode, .rovodev, .hermesAgent:
            return .timelineOnly
        case .registered(let agent):
            if piFamilyIDs.contains(agent.id), entry.fileURL != nil {
                return .piFamily
            }
            return .timelineOnly
        }
    }

    var supportsFork: Bool {
        switch self {
        case .claude, .codex, .grok, .piFamily:
            return true
        case .timelineOnly:
            return false
        }
    }

    // MARK: Derivation

    /// Derives the turn-checkpoint timeline for `entry`. File-backed
    /// harnesses scan raw JSONL (bounded) so anchors exist for forking;
    /// timeline-only harnesses project the transcript loader's turns
    /// (display value, no anchors).
    nonisolated static func derive(for entry: SessionEntry) async -> VaultSessionCheckpoints.Derivation? {
        guard let harness = resolve(for: entry) else { return nil }
        switch harness {
        case .claude:
            guard let url = entry.fileURL else { return nil }
            return VaultSessionCheckpoints.deriveClaudeTurns(fileURL: url)
        case .codex:
            guard let url = entry.fileURL else { return nil }
            return VaultSessionCheckpoints.deriveCodexTurns(fileURL: url)
        case .grok:
            guard let url = entry.fileURL else { return nil }
            return VaultSessionCheckpoints.deriveGrokTurns(fileURL: url)
        case .piFamily:
            guard let url = entry.fileURL else { return nil }
            return VaultSessionCheckpoints.derivePiFamilyTurns(fileURL: url)
        case .timelineOnly:
            return await deriveFromTranscriptLoader(entry: entry)
        }
    }

    /// Display-only checkpoints from the shared transcript loader (all
    /// harnesses it supports, incl. SQLite-backed ones). No anchors → no fork.
    nonisolated private static func deriveFromTranscriptLoader(
        entry: SessionEntry
    ) async -> VaultSessionCheckpoints.Derivation? {
        guard let turns = try? await SessionTranscriptLoader.load(entry: entry) else {
            return nil
        }
        var checkpoints: [VaultSessionCheckpoint] = []
        var turnIndex = 0
        for turn in turns where turn.role == .user {
            turnIndex += 1
            checkpoints.append(
                VaultSessionCheckpoint(
                    id: "turn-index:\(turnIndex)",
                    source: .turn,
                    timestamp: nil,
                    name: nil,
                    turnIndex: turnIndex,
                    anchor: nil,
                    gitSHA: nil,
                    promptSnippet: VaultSessionCheckpoints.snippet(from: turn.text)
                )
            )
        }
        return VaultSessionCheckpoints.Derivation(
            checkpoints: checkpoints,
            isTruncated: false,
            lastAnchor: nil
        )
    }

    // MARK: Fork

    /// Forks `entry` at `checkpoint` into a fresh session id. Throws
    /// `.unsupportedHarness` for timeline-only harnesses. Returns the new
    /// session's transcript file URL (grok: the new `chat_history.jsonl`).
    nonisolated static func fork(
        entry: SessionEntry,
        checkpoint: VaultSessionCheckpoint,
        newSessionID: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try VaultCheckpointForker.validateSessionID(newSessionID)
        guard let harness = resolve(for: entry), harness.supportsFork,
              let parentFileURL = entry.fileURL else {
            throw VaultCheckpointForkError.unsupportedHarness
        }
        switch harness {
        case .claude:
            let plan = VaultForkPlan(
                parentFileURL: parentFileURL,
                destinationFileURL: parentFileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(newSessionID + ".jsonl"),
                anchorToken: { obj, _ in
                    (obj["uuid"] as? String).flatMap { $0.isEmpty ? nil : "uuid:" + $0 }
                },
                userPrompt: VaultSessionCheckpoints.claudeUserPromptText(from:),
                rewriteLine: { obj in
                    guard obj["sessionId"] is String else { return nil }
                    var next = obj
                    next["sessionId"] = newSessionID
                    return next
                }
            )
            return try VaultCheckpointForker.fork(plan: plan, checkpoint: checkpoint, fileManager: fileManager)

        case .codex:
            let plan = VaultForkPlan(
                parentFileURL: parentFileURL,
                destinationFileURL: codexForkDestination(
                    parentFileURL: parentFileURL,
                    newSessionID: newSessionID
                ),
                anchorToken: { obj, index in
                    if let ordinal = obj["ordinal"] as? Int { return "ordinal:\(ordinal)" }
                    return "line:\(index)"
                },
                userPrompt: VaultSessionCheckpoints.codexUserPromptText(from:),
                rewriteLine: { obj in
                    // Identity lives only in the session_meta payload.
                    guard (obj["type"] as? String) == "session_meta",
                          var payload = obj["payload"] as? [String: Any] else {
                        return nil
                    }
                    if payload["id"] is String { payload["id"] = newSessionID }
                    if payload["session_id"] is String { payload["session_id"] = newSessionID }
                    var next = obj
                    next["payload"] = payload
                    return next
                }
            )
            return try VaultCheckpointForker.fork(plan: plan, checkpoint: checkpoint, fileManager: fileManager)

        case .piFamily:
            let plan = VaultForkPlan(
                parentFileURL: parentFileURL,
                destinationFileURL: piFamilyForkDestination(
                    parentFileURL: parentFileURL,
                    newSessionID: newSessionID
                ),
                anchorToken: { obj, index in
                    if let id = obj["id"] as? String, !id.isEmpty { return "id:" + id }
                    return "line:\(index)"
                },
                userPrompt: VaultSessionCheckpoints.piFamilyUserPromptText(from:),
                rewriteLine: { obj in
                    // The first `session` line owns the id; other lines carry
                    // their own short record ids that must stay intact.
                    guard (obj["type"] as? String) == "session", obj["id"] is String else {
                        return nil
                    }
                    var next = obj
                    next["id"] = newSessionID
                    return next
                }
            )
            return try VaultCheckpointForker.fork(plan: plan, checkpoint: checkpoint, fileManager: fileManager)

        case .grok:
            return try forkGrokSessionDirectory(
                parentChatHistoryURL: parentFileURL,
                checkpoint: checkpoint,
                newSessionID: newSessionID,
                fileManager: fileManager
            )

        case .timelineOnly:
            throw VaultCheckpointForkError.unsupportedHarness
        }
    }

    /// `rollout-<orig-ts>-<newid>.jsonl` beside the parent; keeps the parent's
    /// timestamp prefix so Codex's date-sharded layout stays coherent.
    nonisolated static func codexForkDestination(parentFileURL: URL, newSessionID: String) -> URL {
        let directory = parentFileURL.deletingLastPathComponent()
        let base = parentFileURL.deletingPathExtension().lastPathComponent
        // rollout-2026-08-14T20-57-29-<uuid>
        if let range = base.range(of: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#, options: .regularExpression) {
            return directory.appendingPathComponent(String(base[range]) + "-" + newSessionID + ".jsonl")
        }
        return directory.appendingPathComponent("rollout-" + newSessionID + ".jsonl")
    }

    /// `<orig-ts>_<newid>.jsonl` beside the parent (pi names sessions
    /// `<timestamp>_<uuid>.jsonl` and resolves `--session <uuid>` by scan).
    nonisolated static func piFamilyForkDestination(parentFileURL: URL, newSessionID: String) -> URL {
        let directory = parentFileURL.deletingLastPathComponent()
        let base = parentFileURL.deletingPathExtension().lastPathComponent
        if let underscore = base.lastIndex(of: "_") {
            return directory.appendingPathComponent(String(base[..<underscore]) + "_" + newSessionID + ".jsonl")
        }
        return directory.appendingPathComponent(newSessionID + ".jsonl")
    }

    /// Grok sessions are directories (`<encoded-cwd>/<session-id>/`) holding
    /// `chat_history.jsonl` plus sidecar state. Fork = new sibling directory
    /// named by the new id with a truncated chat history; small sidecar files
    /// copy verbatim so grok keeps its prompt context. Telemetry
    /// (`events.jsonl`) and lock files stay behind.
    nonisolated static func forkGrokSessionDirectory(
        parentChatHistoryURL: URL,
        checkpoint: VaultSessionCheckpoint,
        newSessionID: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let parentDirectory = parentChatHistoryURL.deletingLastPathComponent()
        let sessionsRoot = parentDirectory.deletingLastPathComponent()
        let newDirectory = sessionsRoot.appendingPathComponent(newSessionID, isDirectory: true)
        do {
            try fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: false)
        } catch {
            throw VaultCheckpointForkError.writeFailed
        }
        var succeeded = false
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: newDirectory)
            }
        }

        let plan = VaultForkPlan(
            parentFileURL: parentChatHistoryURL,
            destinationFileURL: newDirectory.appendingPathComponent("chat_history.jsonl"),
            anchorToken: { _, index in "line:\(index)" },
            userPrompt: VaultSessionCheckpoints.grokUserPromptText(from:),
            rewriteLine: { _ in nil }
        )
        let destination = try VaultCheckpointForker.fork(
            plan: plan,
            checkpoint: checkpoint,
            fileManager: fileManager
        )

        for sidecar in ["prompt_context.json", "resources_state.json", "summary.json"] {
            let source = parentDirectory.appendingPathComponent(sidecar)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                // A sidecar that exists but fails to copy must fail the fork:
                // reporting success would hand back a resumable session
                // missing its prompt/session state.
                try fileManager.copyItem(
                    at: source,
                    to: newDirectory.appendingPathComponent(sidecar)
                )
            } catch {
                throw VaultCheckpointForkError.writeFailed
            }
        }

        succeeded = true
        return destination
    }
}
