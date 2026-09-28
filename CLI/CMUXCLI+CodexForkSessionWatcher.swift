import CMUXAgentLaunch
import Darwin
import Foundation

/// Correlates a Codex fork launch with the rollout that Codex creates before
/// the first user prompt. The wrapper starts this watcher before replacing
/// itself with Codex; the watcher then routes the discovered identity through
/// the normal `SessionStart` hook path.
struct CodexForkSessionWatcher {
    static let parentSessionEnvironmentKey = "CMUX_AGENT_FORK_PARENT_SESSION_ID"
    static let launchAtEnvironmentKey = "CMUX_AGENT_FORK_LAUNCH_AT"
    static let forkSessionEnvironmentKey = "CMUX_CODEX_FORK_SESSION"

    struct ChildSession: Equatable {
        let sessionID: String
        let transcriptPath: String
    }

    private static let maximumDirectories = 512
    private static let maximumRollouts = 2_048
    private static let maximumMetadataBytes = 1 * 1_024 * 1_024
    private static let watchTimeout: TimeInterval = 15

    let parentSessionID: String
    let sessionsRoot: URL
    let launchedAt: Date
    let fileManager: FileManager

    init(
        parentSessionID: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        self.parentSessionID = parentSessionID
        self.fileManager = fileManager
        sessionsRoot = URL(
            fileURLWithPath: CodexHomeResolver().resolve(ambientEnvironment: environment),
            isDirectory: true
        ).appendingPathComponent("sessions", isDirectory: true)
        let launchTimestamp = Double(environment[Self.launchAtEnvironmentKey] ?? "") ?? Date.now.timeIntervalSince1970
        launchedAt = Date(timeIntervalSince1970: launchTimestamp)
    }

    func wait() -> ChildSession? {
        if let child = Self.findForkedSession(
            parentSessionID: parentSessionID,
            sessionsRoot: sessionsRoot,
            launchedAt: launchedAt,
            fileManager: fileManager
        ) {
            return child
        }

        let signal = DispatchSemaphore(value: 0)
        let sources = directorySources { signal.signal() }
        guard !sources.isEmpty else { return nil }
        defer { sources.forEach { $0.cancel() } }

        let deadline = Date.now.addingTimeInterval(Self.watchTimeout)
        while Date.now < deadline {
            if let child = Self.findForkedSession(
                parentSessionID: parentSessionID,
                sessionsRoot: sessionsRoot,
                launchedAt: launchedAt,
                fileManager: fileManager
            ) {
                return child
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // This semaphore only bridges DispatchSource filesystem events to
            // the short-lived CLI watcher; it does not guard mutable state.
            _ = signal.wait(timeout: .now() + min(remaining, 1))
        }
        return Self.findForkedSession(
            parentSessionID: parentSessionID,
            sessionsRoot: sessionsRoot,
            launchedAt: launchedAt,
            fileManager: fileManager
        )
    }

    static func findForkedSession(
        parentSessionID: String,
        sessionsRoot: URL,
        launchedAt: Date,
        fileManager: FileManager = .default
    ) -> ChildSession? {
        guard !parentSessionID.isEmpty,
              let enumerator = fileManager.enumerator(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [(ChildSession, Date)] = []
        var scanned = 0
        while let item = enumerator.nextObject() as? URL, scanned < Self.maximumRollouts {
            scanned += 1
            guard item.pathExtension.lowercased() == "jsonl",
                  let metadata = readMetadata(at: item),
                  metadata.parentSessionID == parentSessionID,
                  metadata.sessionID != parentSessionID else {
                continue
            }
            let resourceValues = try? item.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey]
            )
            let fileDate = resourceValues?.creationDate
                ?? resourceValues?.contentModificationDate
                ?? .distantPast
            let candidateDate = metadata.timestamp ?? fileDate
            guard candidateDate.timeIntervalSince1970 >= launchedAt.timeIntervalSince1970 - 2 else {
                continue
            }
            candidates.append((ChildSession(sessionID: metadata.sessionID, transcriptPath: item.path), candidateDate))
        }
        return candidates.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.transcriptPath < rhs.0.transcriptPath
        }?.0
    }

    private struct Metadata {
        let sessionID: String
        let parentSessionID: String?
        let timestamp: Date?
    }

    private static func readMetadata(at url: URL) -> Metadata? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumMetadataBytes),
              let firstLine = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionID = normalized(payload["id"] as? String) else {
            return nil
        }
        let parentSessionID = normalized(payload["forked_from_id"] as? String)
            ?? normalized(payload["parent_thread_id"] as? String)
        let timestamp = (payload["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Metadata(sessionID: sessionID, parentSessionID: parentSessionID, timestamp: timestamp)
    }

    private func directorySources(onEvent: @escaping () -> Void) -> [DispatchSourceFileSystemObject] {
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return [] }
        var directories: [URL] = [sessionsRoot]
        if let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while directories.count < Self.maximumDirectories,
                  let item = enumerator.nextObject() as? URL {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.append(item)
                }
            }
        }

        return directories.compactMap { directory in
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler(handler: onEvent)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return source
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension CMUXCLI {
    /// Runs the fork watcher in the detached monitor process started by the Codex wrapper.
    func runCodexForkSessionWatch(
        commandArgs: [String],
        parentSessionID: String,
        client: SocketClient
    ) {
        let environment = ProcessInfo.processInfo.environment
        let workspaceID = optionValue(commandArgs, name: "--workspace")
            ?? environment["CMUX_WORKSPACE_ID"]
        let surfaceID = optionValue(commandArgs, name: "--surface")
            ?? environment["CMUX_SURFACE_ID"]
        guard let workspaceID, let surfaceID,
              !workspaceID.isEmpty, !surfaceID.isEmpty else {
            return
        }

        let watcher = CodexForkSessionWatcher(
            parentSessionID: parentSessionID,
            environment: environment
        )
        if let child = watcher.wait() {
            launchCodexForkSessionStart(
                child: child,
                parentSessionID: parentSessionID,
                environment: environment,
                client: client
            )
            return
        }

        _ = try? client.sendV2(method: "surface.resume.clear", params: [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "checkpoint_id": parentSessionID,
            "source": "agent-hook",
        ])
        let title = String(localized: "agent.codex.fork.notice.title", defaultValue: "Codex fork")
        let body = String(
            localized: "agent.codex.fork.notice.body",
            defaultValue: "cmux could not identify the new fork session, so this pane was not bound to the parent. Start the fork again from the parent pane."
        )
        _ = try? client.sendV2(method: "notification.create_for_target", params: [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "title": title,
            "subtitle": String(localized: "agent.codex.fork.notice.subtitle", defaultValue: "Fork unavailable"),
            "body": body,
        ])
    }

    private func launchCodexForkSessionStart(
        child: CodexForkSessionWatcher.ChildSession,
        parentSessionID: String,
        environment: [String: String],
        client: SocketClient
    ) {
        let executable = CommandLine.arguments.first ?? "cmux"
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--socket", client.socketPath, "hooks", "codex", "session-start"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "--socket", client.socketPath, "hooks", "codex", "session-start"]
        }
        var childEnvironment = environment
        childEnvironment[CodexForkSessionWatcher.forkSessionEnvironmentKey] = "1"
        process.environment = childEnvironment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let payload: [String: Any] = [
                "session_id": child.sessionID,
                "forked_from_id": parentSessionID,
                "transcript_path": child.transcriptPath,
                "cwd": childEnvironment["PWD"] ?? FileManager.default.currentDirectoryPath,
                "hook_event_name": "SessionStart",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                input.fileHandleForWriting.write(data)
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            try? input.fileHandleForWriting.close()
        }
    }

    /// Filesystem events are the only synchronization primitive used by the
    /// rollout monitor; the semaphore bridge remains bounded by the watch deadline.
    func waitForCodexTranscriptChange(path: String?, leasePath: String?, timeout: TimeInterval) {
        guard timeout > 0 else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var sources: [DispatchSourceFileSystemObject] = []

        func addFileSource(path: String?, eventMask: DispatchSource.FileSystemEvent) {
            guard let path, !path.isEmpty else { return }
            let expandedPath = NSString(string: path).expandingTildeInPath
            let descriptor = open(expandedPath, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: eventMask,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { semaphore.signal() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }

        addFileSource(path: path, eventMask: [.write, .extend, .delete, .rename])
        addFileSource(path: leasePath, eventMask: [.write, .delete, .rename])
        guard !sources.isEmpty else {
            _ = semaphore.wait(timeout: .now() + timeout)
            return
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        sources.forEach { $0.cancel() }
    }
}
