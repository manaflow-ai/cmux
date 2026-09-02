import CmuxAgentJournal
import Foundation

extension CMUXCLI {
    /// Emits one semantic agent event into the app's append-only agent
    /// journal and blocks until the app acknowledges the durable commit.
    ///
    /// This is the structured replacement for the fire-and-forget
    /// `set_agent_lifecycle` verb: sidebar lifecycle is now a reduction over
    /// these events. Attribution is decided by the caller — an event that
    /// could not be attributed carries `unattributedReason` (and no target)
    /// so the app surfaces it as a diagnostic instead of guessing a pane.
    ///
    /// Delivery failures are never silent: they land in the dead-letter file
    /// and, when a session store and telemetry are provided, in the throttled
    /// hook-failure report channel.
    func emitAgentJournalEvent(
        client: SocketClient,
        kind: AgentJournalEventKind,
        source: String,
        agentKey: String,
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?,
        unattributedReason: String? = nil,
        isSubagent: Bool = false,
        pendingWork: Bool = false,
        nativeEvent: String?,
        declaredPhase: AgentLifecyclePhase? = nil,
        detail: String? = nil,
        responseTimeout: TimeInterval? = nil,
        deadline: Date? = nil,
        store: ClaudeHookSessionStore? = nil,
        telemetry: CLISocketSentryTelemetry? = nil
    ) {
        // A malformed or partial target (empty string, non-UUID, missing
        // half) is never trusted: the event is journaled as an explicit
        // diagnostic instead of being rejected at admission or guessed.
        let validWorkspaceId = workspaceId.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let validSurfaceId = surfaceId.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let hasCompleteTarget = validWorkspaceId != nil && validSurfaceId != nil
        let resolvedReason: String?
        if let unattributedReason {
            resolvedReason = unattributedReason
        } else if !hasCompleteTarget {
            resolvedReason = "malformed-target"
        } else {
            resolvedReason = nil
        }
        let draft = AgentJournalEventDraft(
            kind: kind,
            occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            source: source,
            agentKey: agentKey,
            sessionId: sessionId,
            workspaceId: resolvedReason == nil ? validWorkspaceId : nil,
            surfaceId: resolvedReason == nil ? validSurfaceId : nil,
            unattributedReason: resolvedReason,
            isSubagent: isSubagent,
            pendingWork: pendingWork,
            nativeEvent: nativeEvent,
            declaredPhase: declaredPhase,
            detail: detail
        )
        if let problem = draft.validationProblem() {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: "invalid draft: \(problem)",
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(draft),
              let json = String(data: data, encoding: .utf8) else {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: "encode failed",
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
            return
        }
        do {
            let response: String
            if responseTimeout != nil || deadline != nil {
                response = try client.send(
                    command: "agent_journal_append \(json)",
                    responseTimeout: responseTimeout,
                    deadline: deadline
                )
            } else {
                response = try sendV1Command("agent_journal_append \(json)", client: client)
            }
            guard response.hasPrefix("OK") else {
                recordAgentJournalDeliveryFailure(
                    draft: draft,
                    message: response,
                    store: store,
                    telemetry: telemetry,
                    deadline: deadline
                )
                return
            }
        } catch {
            recordAgentJournalDeliveryFailure(
                draft: draft,
                message: String(describing: error),
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
        }
    }

    /// Resolves the semantic kind for a generic agent hook's `notification`
    /// action: the native event name maps first (`StopFailure`,
    /// `pre_approval_request`, …); only when the mapper has nothing stronger
    /// than an observation does the prose classifier's verdict fill in, as a
    /// last-resort adapter detail.
    func agentJournalNotificationKind(
        def: AgentHookDef,
        nativeEvent: String?,
        toolName: String?,
        summary: AgentHookNotificationSummary
    ) -> AgentJournalEventKind {
        let mapper = AgentSemanticEventMapper()
        if let nativeEvent, !nativeEvent.isEmpty {
            let mapped = mapper.kind(source: def.name, nativeEvent: nativeEvent, toolName: toolName)
            if mapped != .stateChanged {
                return mapped
            }
        }
        switch summary.status {
        case .needsInput?:
            return summary.notifyCategory == .needsPermission ? .approvalRequested : .questionRequested
        case .error?:
            return .errorReported
        case .idle?:
            return .turnCompleted
        case nil:
            return .stateChanged
        }
    }

    /// Records a failed journal emission: appended to the bounded dead-letter
    /// file, warned on stderr, and (when possible) reported through the
    /// throttled hook-failure channel. Never silent.
    func recordAgentJournalDeliveryFailure(
        draft: AgentJournalEventDraft,
        message: String,
        store: ClaudeHookSessionStore?,
        telemetry: CLISocketSentryTelemetry?,
        deadline: Date? = nil
    ) {
        appendAgentJournalDeadLetter(draft: draft, message: message)
        cliWriteStderr("Warning: agent journal append failed (\(draft.kind.rawValue)): \(message)\n")
        if let store, let telemetry {
            reportAgentHookFailure(
                stage: .journalAppend,
                agentName: draft.source,
                sessionId: draft.sessionId ?? "",
                event: draft.nativeEvent ?? draft.kind.rawValue,
                error: nil,
                store: store,
                telemetry: telemetry,
                deadline: deadline
            )
        }
    }

    /// Dead-letter location: one JSON line per failed emission, bounded by
    /// truncation so an unreachable app cannot grow it without limit.
    static func agentJournalDeadLetterURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = env["CMUX_AGENT_JOURNAL_DEAD_LETTER_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("agent-journal-dead-letter.jsonl", isDirectory: false)
    }

    private func appendAgentJournalDeadLetter(draft: AgentJournalEventDraft, message: String) {
        let url = Self.agentJournalDeadLetterURL()
        let maximumBytes: UInt64 = 1_048_576
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
               size > maximumBytes {
                try? fileManager.removeItem(at: url)
            }
            var record: [String: Any] = [
                "at_ms": Int64(Date().timeIntervalSince1970 * 1000),
                "error": message,
            ]
            if let draftData = try? JSONEncoder().encode(draft),
               let draftObject = try? JSONSerialization.jsonObject(with: draftData) {
                record["event"] = draftObject
            }
            let lineData = try JSONSerialization.data(withJSONObject: record)
            guard var line = String(data: lineData, encoding: .utf8) else { return }
            line += "\n"
            // O_APPEND with one write(2) call keeps concurrent hook
            // processes' records intact (no read-modify-write interleaving).
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            _ = Array(line.utf8).withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
        } catch {
            // stderr warning above already made the failure visible.
        }
    }
}
