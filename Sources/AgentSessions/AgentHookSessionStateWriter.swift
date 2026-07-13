import Darwin
import Foundation

/// Completes a hook-store session after cmux observes the root TUI return to its
/// shell prompt. Work runs on a utility queue and uses the same sidecar lock as
/// hook writers, so terminal UI delivery never waits on disk or JSON work.
struct AgentHookSessionStateWriter: Sendable {
    private static let queue = DispatchQueue(
        label: "com.cmux.agent-session-completion",
        qos: .utility
    )
    private let homeDirectory: String
    private let environment: [String: String]

    init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    static func rootExitCandidate(
        previousWasRunning: Bool,
        isPromptIdle: Bool,
        isHibernated: Bool,
        binding: SurfaceResumeBindingSnapshot?
    ) -> SurfaceResumeBindingSnapshot? {
        previousWasRunning && isPromptIdle && !isHibernated && binding?.isAgentHookBinding == true
            ? binding
            : nil
    }

    static func recordRootExitIfNeeded(
        binding: SurfaceResumeBindingSnapshot?
    ) {
        guard let kindValue = binding?.kind,
              let kind = RestorableAgentKind(rawValue: kindValue),
              let sessionId = binding?.checkpointId else { return }
        AgentHookSessionStateWriter().schedule(
            kind: kind,
            sessionId: sessionId,
            expectedRecordUpdatedAt: binding?.updatedAt
        )
    }

    static func recordLifecycle(
        agent: SessionRestorableAgentSnapshot?,
        state: AgentSessionLifecycleState
    ) {
        guard let agent else { return }
        AgentHookSessionStateWriter().scheduleLifecycle(
            kind: agent.kind,
            sessionId: agent.sessionId,
            state: state
        )
    }

    func schedule(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Self.queue.async {
            complete(
                stateURL: stateURL,
                sessionId: normalized,
                expectedRecordUpdatedAt: expectedRecordUpdatedAt,
                now: now
            )
        }
    }

    func completeSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval? = nil,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        complete(
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            expectedRecordUpdatedAt: expectedRecordUpdatedAt,
            now: now
        )
    }

    func scheduleLifecycle(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let stateURL = kind.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        Self.queue.async {
            setLifecycle(state, stateURL: stateURL, sessionId: normalized, now: now)
        }
    }

    func setLifecycleSynchronously(
        kind: RestorableAgentKind,
        sessionId: String,
        state: AgentSessionLifecycleState,
        now: TimeInterval
    ) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        setLifecycle(
            state,
            stateURL: kind.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            sessionId: normalized,
            now: now
        )
    }

    private func complete(
        stateURL: URL,
        sessionId: String,
        expectedRecordUpdatedAt: TimeInterval?,
        now: TimeInterval
    ) {
        let lockPath = stateURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }

        guard let data = try? Data(contentsOf: stateURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sessions = root["sessions"] as? [String: Any],
              var record = sessions[sessionId] as? [String: Any] else {
            return
        }
        // The binding timestamp is a lock-free generation fence captured when
        // the terminal observed the root TUI exit. A newer hook/store write
        // means this queued completion belongs to the replaced process.
        if let expectedRecordUpdatedAt {
            guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
                  actualUpdatedAt <= expectedRecordUpdatedAt else { return }
        }

        record["completedAt"] = now
        record["updatedAt"] = now
        record["runtimeStatus"] = "idle"
        record["agentLifecycle"] = "idle"
        if record["foregroundState"] as? String != "interrupted" {
            record["foregroundState"] = "completed"
        }
        record["attentionState"] = "none"
        record["sessionState"] = "ended"
        record["restoreAuthority"] = false
        record.removeValue(forKey: "activeRunId")
        record["runs"] = completeRuns(record["runs"], now: now)
        record["workloads"] = cancelWorkloads(record["workloads"], now: now)
        sessions[sessionId] = record
        root["sessions"] = sessions
        root["activeSessionsByWorkspace"] = removingSession(
            sessionId,
            from: root["activeSessionsByWorkspace"]
        )
        root["activeSessionsBySurface"] = removingSession(
            sessionId,
            from: root["activeSessionsBySurface"]
        )

        guard JSONSerialization.isValidJSONObject(root),
              let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? encoded.write(to: stateURL, options: .atomic)
    }

    private func setLifecycle(
        _ lifecycle: AgentSessionLifecycleState,
        stateURL: URL,
        sessionId: String,
        now: TimeInterval
    ) {
        let lockPath = stateURL.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard let data = try? Data(contentsOf: stateURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var sessions = root["sessions"] as? [String: Any],
              var record = sessions[sessionId] as? [String: Any] else { return }
        // `now` is captured before this write enters the utility queue. A hook
        // write with a later timestamp belongs to a newer process generation,
        // so this queued lifecycle transition must not move that record or its
        // runtime ownership backwards.
        guard let actualUpdatedAt = record["updatedAt"] as? TimeInterval,
              actualUpdatedAt <= now else { return }
        record["sessionState"] = lifecycle.rawValue
        record["updatedAt"] = now
        if let runtime = runtimePayload() {
            record["cmuxRuntime"] = runtime
            record["runs"] = assigningRuntime(
                runtime,
                to: record["runs"],
                activeRunId: record["activeRunId"] as? String
            )
        }
        sessions[sessionId] = record
        root["sessions"] = sessions
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? encoded.write(to: stateURL, options: .atomic)
    }

    private func completeRuns(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]] else { return [] }
        return runs.map { run in
            var run = run
            if run["endedAt"] == nil {
                run["endedAt"] = now
                run["updatedAt"] = now
                run["restoreAuthority"] = false
            }
            return run
        }
    }

    private func runtimePayload() -> [String: Any]? {
        guard let id = environment["CMUX_RUNTIME_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        var payload: [String: Any] = ["id": id]
        if let socketPath = environment["CMUX_SOCKET_PATH"], !socketPath.isEmpty {
            payload["socketPath"] = socketPath
        }
        if let bundleIdentifier = environment["CMUX_BUNDLE_ID"], !bundleIdentifier.isEmpty {
            payload["bundleIdentifier"] = bundleIdentifier
        }
        return payload
    }

    private func assigningRuntime(
        _ runtime: [String: Any],
        to value: Any?,
        activeRunId: String?
    ) -> [[String: Any]] {
        guard let runs = value as? [[String: Any]], let activeRunId else { return value as? [[String: Any]] ?? [] }
        return runs.map { run in
            guard run["runId"] as? String == activeRunId else { return run }
            var updated = run
            updated["cmuxRuntime"] = runtime
            return updated
        }
    }

    private func cancelWorkloads(_ value: Any?, now: TimeInterval) -> [[String: Any]] {
        guard let workloads = value as? [[String: Any]] else { return [] }
        let activePhases: Set<String> = ["queued", "running", "watching", "waiting"]
        return workloads.map { workload in
            var workload = workload
            if let phase = workload["phase"] as? String, activePhases.contains(phase) {
                workload["phase"] = "cancelled"
                workload["updatedAt"] = now
                workload["endedAt"] = now
                workload["endReason"] = "root_exited"
            }
            return workload
        }
    }

    private func removingSession(_ sessionId: String, from value: Any?) -> [String: Any] {
        guard var records = value as? [String: Any] else { return [:] }
        for (key, value) in records {
            guard let record = value as? [String: Any],
                  record["sessionId"] as? String == sessionId else { continue }
            records.removeValue(forKey: key)
        }
        return records
    }
}
