import Darwin
import Foundation
import Observation

/// Reads cmux's agent-hook session stores and watches their directory for atomic
/// file replacements. This is a local bridge until lifecycle becomes part of
/// the public CmuxExtensionKit surface snapshot.
final class AgentLifecycleMonitor: @unchecked Sendable {
    typealias Statuses = [UUID: SurfaceAgentLifecycle]

    private struct DirectStatusFile: Decodable {
        let version: Int
        let agentID: String
        let surfaceID: String
        let state: SurfaceAgentLifecycle.State
        let reason: SurfaceAgentLifecycle.Reason?
        let statusMessage: String?
        let pid: Int32?
        let updatedAt: TimeInterval
    }

    private struct CodexLaunchFile: Decodable {
        let schemaVersion: Int
        let kind: String
        let agentID: String
        let surfaceID: String
        let pid: Int32
        let createdAt: TimeInterval
    }

    private struct StoreFile: Decodable {
        struct ActiveSession: Decodable {
            let sessionId: String
        }

        struct Session: Decodable {
            let sessionId: String?
            let agentLifecycle: SurfaceAgentLifecycle.State?
            let runtimeStatus: String?
            let pid: Int32?
            let surfaceId: String
            let transcriptPath: String?
            let updatedAt: TimeInterval?
        }

        let activeSessionsBySurface: [String: ActiveSession]?
        let sessions: [String: Session]
    }

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "dev.vincent.cmux.surface-status.lifecycle", qos: .utility)
    private let decoder = JSONDecoder()
    private let onChange: @MainActor @Sendable (Statuses) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var refreshTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    private var watchedProcessBirths: [Int32: CodexProcessSnapshot] = [:]
    private var pendingReload: DispatchWorkItem?

    init(onChange: @escaping @MainActor @Sendable (Statuses) -> Void) {
        // In an App Sandbox extension, Foundation's homeDirectoryForCurrentUser
        // resolves to the extension container. The temporary home-relative
        // entitlement, however, grants access relative to the account's real
        // home directory. Resolve that home from the passwd database so we read
        // ~/.cmuxterm rather than an empty container-local directory.
        let accountHome: URL
        if let passwd = getpwuid(getuid()), let homePath = passwd.pointee.pw_dir {
            accountHome = URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
        } else if let homePath = ProcessInfo.processInfo.environment["HOME"] {
            accountHome = URL(fileURLWithPath: homePath, isDirectory: true)
        } else {
            accountHome = FileManager.default.homeDirectoryForCurrentUser
        }
        directoryURL = accountHome.appendingPathComponent(".cmuxterm", isDirectory: true)
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reload()
            self.installDirectoryWatcher()
            self.installRefreshTimer()
            self.installLivenessTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            self.pendingReload = nil
            self.directorySource?.cancel()
            self.directorySource = nil
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            self.livenessTimer?.cancel()
            self.livenessTimer = nil
            self.watchedProcessBirths = [:]
        }
    }

    private func installDirectoryWatcher() {
        guard directorySource == nil else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let events = source?.data ?? []
            self.scheduleReload()
            if !events.intersection([.rename, .delete]).isEmpty {
                self.directorySource?.cancel()
                self.directorySource = nil
            }
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func installRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Filesystem events drive lifecycle transitions. This slower sweep is
        // only a safety net for missed events and dead-PID reconciliation.
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.directorySource == nil { self.installDirectoryWatcher() }
            self.pendingReload?.cancel()
            self.pendingReload = nil
            self.reload()
        }
        refreshTimer = timer
        timer.resume()
    }

    private func installLivenessTimer() {
        guard livenessTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let processChanged = self.watchedProcessBirths.contains { pid, expected in
                self.processSnapshot(pid) != expected
            }
            if processChanged { self.reload() }
        }
        livenessTimer = timer
        timer.resume()
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + .milliseconds(30), execute: work)
    }

    private func reload() {
        let statuses = loadStatuses()
        Task { @MainActor [onChange] in
            onChange(statuses)
        }
    }

    private func loadStatuses() -> Statuses {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: Statuses = [:]
        var directStatusUpdatedAt: [String: TimeInterval] = [:]
        var projectedCodexPIDs: [UUID: Int32] = [:]

        for file in files where file.lastPathComponent.hasSuffix("-sidebar-agent-status.json") {
            guard let data = try? Data(contentsOf: file),
                  let status = try? decoder.decode(DirectStatusFile.self, from: data),
                  status.version == 2,
                  !status.agentID.isEmpty,
                  let surfaceID = UUID(uuidString: status.surfaceID),
                  let pid = status.pid,
                  processIsAlive(pid) else {
                continue
            }
            directStatusUpdatedAt["\(status.agentID):\(surfaceID.uuidString)"] = status.updatedAt
            let candidate = SurfaceAgentLifecycle(
                agentID: status.agentID,
                state: status.state,
                reason: status.reason,
                updatedAt: status.updatedAt,
                statusMessage: status.statusMessage
            )
            if let current = result[surfaceID], !candidateShouldReplace(candidate, current) {
                continue
            }
            result[surfaceID] = candidate
        }

        let codexLaunches: [CodexLaunchPresence] = files.compactMap { file in
            guard file.lastPathComponent.hasPrefix("codex-"),
                  file.lastPathComponent.hasSuffix("-sidebar-agent-launch.json"),
                  let data = try? Data(contentsOf: file),
                  let launch = try? decoder.decode(CodexLaunchFile.self, from: data),
                  launch.schemaVersion == 1,
                  launch.kind == "codex-launch",
                  launch.agentID == "codex" else {
                return nil
            }
            return CodexLaunchPresence(
                surfaceID: launch.surfaceID,
                pid: launch.pid,
                createdAt: launch.createdAt
            )
        }

        var processedCodexStore = false
        for file in files where file.lastPathComponent.hasSuffix("-hook-sessions.json") {
            let agentID = String(file.lastPathComponent.dropLast("-hook-sessions.json".count))
            // Pi has a dedicated direct status source; skip its larger,
            // chat-bearing hook store before any file read or JSON decode.
            if agentID == "pi" { continue }
            guard let data = try? Data(contentsOf: file),
                  let store = try? decoder.decode(StoreFile.self, from: data) else {
                continue
            }

            if agentID == "codex" {
                processedCodexStore = true
                let sessions = Dictionary(uniqueKeysWithValues: store.sessions.map { sessionID, session in
                    (sessionID, CodexLifecycleSession(
                        sessionID: session.sessionId ?? sessionID,
                        agentLifecycle: session.agentLifecycle,
                        runtimeStatus: session.runtimeStatus,
                        pid: session.pid,
                        surfaceID: session.surfaceId,
                        updatedAt: session.updatedAt
                    ))
                })
                let activeBySurface = store.activeSessionsBySurface?.mapValues(\.sessionId)
                let codexStatuses = CodexLifecycleProjection.statuses(
                    sessions: sessions,
                    activeSessionsBySurface: activeBySurface,
                    launches: codexLaunches,
                    now: Date().timeIntervalSince1970,
                    processLookup: processSnapshot
                )
                for (surfaceID, candidate) in codexStatuses {
                    if let current = result[surfaceID], !candidateShouldReplace(candidate, current) {
                        continue
                    }
                    result[surfaceID] = candidate
                    if let activeSessionID = activeBySurface?[surfaceID.uuidString],
                       let pid = sessions[activeSessionID]?.pid {
                        projectedCodexPIDs[surfaceID] = pid
                    } else if let pid = sessions.values
                        .filter({ UUID(uuidString: $0.surfaceID) == surfaceID && $0.pid != nil })
                        .max(by: { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) })?.pid {
                        projectedCodexPIDs[surfaceID] = pid
                    } else if let launch = codexLaunches
                        .filter({ UUID(uuidString: $0.surfaceID) == surfaceID })
                        .max(by: { $0.createdAt < $1.createdAt }) {
                        projectedCodexPIDs[surfaceID] = launch.pid
                    }
                }
                continue
            }

            let activeSessionIDs = store.activeSessionsBySurface.map { Set($0.values.map(\.sessionId)) }

            for (sessionID, session) in store.sessions {
                // A present active map is authoritative, including when empty.
                // Claude is the exception: its SessionStart record can carry a
                // valid surface and live process before cmux populates the active
                // map. Accept only that process-verified record; other agents
                // and dead Claude sessions continue to fail closed.
                let hasLiveProcess = session.pid.map(processIsAlive) ?? false
                if let activeSessionIDs,
                   !activeSessionIDs.contains(sessionID),
                   !(agentID == "claude" && hasLiveProcess) {
                    continue
                }
                guard let surfaceID = UUID(uuidString: session.surfaceId), hasLiveProcess else { continue }

                let transcriptStatus = agentID == "claude"
                    ? session.transcriptPath.flatMap(latestClaudeRateLimit)
                    : nil
                let runtimeError = session.runtimeStatus == "error"
                let runtimeState: SurfaceAgentLifecycle.State = switch session.runtimeStatus {
                case "running": .running
                case "idle": .idle
                case "needsInput": .needsInput
                default: .unknown
                }
                let reportedState = session.agentLifecycle ?? runtimeState
                // Claude emits `unknown` at SessionStart even though a live,
                // surface-bound process is already waiting for work. Treat only
                // that process-verified initial state as idle; explicit lifecycle
                // and runtime states still take precedence.
                let lifecycleState: SurfaceAgentLifecycle.State =
                    agentID == "claude" && hasLiveProcess && reportedState == .unknown
                        ? .idle
                        : reportedState
                let candidate = SurfaceAgentLifecycle(
                    agentID: agentID,
                    state: transcriptStatus == nil
                        ? (runtimeError ? .needsInput : lifecycleState)
                        : .rateLimited,
                    reason: transcriptStatus == nil ? (runtimeError ? .error : nil) : .rateLimit,
                    updatedAt: session.updatedAt ?? 0,
                    statusMessage: transcriptStatus
                )
                // Prefer a direct report only while it is at least as recent as
                // cmux's hook store. A live Pi PID alone cannot prove that an
                // extension which stopped reporting still owns current state.
                if let current = result[surfaceID],
                   current.agentID == agentID,
                   let directUpdatedAt = directStatusUpdatedAt["\(agentID):\(surfaceID.uuidString)"],
                   directUpdatedAt >= candidate.updatedAt {
                    continue
                }
                if let current = result[surfaceID], !candidateShouldReplace(candidate, current) {
                    continue
                }
                result[surfaceID] = candidate
            }
        }

        if !processedCodexStore {
            let launchStatuses = CodexLifecycleProjection.statuses(
                sessions: [:],
                activeSessionsBySurface: nil,
                launches: codexLaunches,
                now: Date().timeIntervalSince1970,
                processLookup: processSnapshot
            )
            for (surfaceID, candidate) in launchStatuses {
                if let current = result[surfaceID], !candidateShouldReplace(candidate, current) { continue }
                result[surfaceID] = candidate
                if let launch = codexLaunches
                    .filter({ UUID(uuidString: $0.surfaceID) == surfaceID })
                    .max(by: { $0.createdAt < $1.createdAt }) {
                    projectedCodexPIDs[surfaceID] = launch.pid
                }
            }
        }
        watchedProcessBirths = Dictionary(uniqueKeysWithValues: Set(projectedCodexPIDs.values).compactMap { pid in
            processSnapshot(pid).map { (pid, $0) }
        })
        return result
    }

    private func latestClaudeRateLimit(transcriptPath: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: transcriptPath)) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            let end = try handle.seekToEnd()
            let readLength = min(end, 64 * 1024)
            let startsMidFile = readLength < end
            try handle.seek(toOffset: end - readLength)
            var tail = try handle.readToEnd() ?? Data()
            if startsMidFile, let newline = tail.firstIndex(of: 0x0A) {
                tail = tail[tail.index(after: newline)...]
            }
            let text = String(decoding: tail, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if object["type"] as? String == "user" { return nil }
                guard object["type"] as? String == "assistant",
                      object["error"] as? String == "rate_limit",
                      object["isApiErrorMessage"] as? Bool == true,
                      let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else { continue }
                let status = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return status.isEmpty ? nil : status
            }
        } catch {
            return nil
        }
        return nil
    }

    private func candidateShouldReplace(
        _ candidate: SurfaceAgentLifecycle,
        _ current: SurfaceAgentLifecycle
    ) -> Bool {
        // Lifecycle state is recoverable: a newer Running/Done report must be
        // allowed to clear an older Needs Input or Rate Limit report.
        return candidate.updatedAt > current.updatedAt
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func processSnapshot(_ pid: Int32) -> CodexProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        if size == expectedSize {
            return CodexProcessSnapshot(
                startedAt: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            )
        }
        // Codex requires an exact process birth time, not just kill(pid, 0),
        // so PID reuse cannot revive an old persistent record.
        return nil
    }
}
