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
    static let launchIDEnvironmentKey = "CMUX_AGENT_FORK_LAUNCH_ID"
    static let forkSessionEnvironmentKey = "CMUX_CODEX_FORK_SESSION"

    struct ChildSession: Equatable {
        let sessionID: String
        let transcriptPath: String
    }

    private static let maximumDirectories = 512
    private static let maximumMetadataBytes = 1 * 1_024 * 1_024
    private static let watchTimeout: TimeInterval = 15

    let parentSessionID: String
    let sessionsRoot: URL
    let launchedAt: Date
    let launchID: String
    let ownerPID: Int
    let claimsDirectory: URL
    let fileManager: FileManager

    init(
        parentSessionID: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        self.parentSessionID = parentSessionID
        self.fileManager = fileManager
        launchID = environment[Self.launchIDEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ownerPID = Int(environment["CMUX_CODEX_PID"] ?? "") ?? 0
        sessionsRoot = URL(
            fileURLWithPath: CodexHomeResolver().resolve(ambientEnvironment: environment),
            isDirectory: true
        ).appendingPathComponent("sessions", isDirectory: true)
        let launchTimestamp = Double(environment[Self.launchAtEnvironmentKey] ?? "") ?? Date.now.timeIntervalSince1970
        launchedAt = Date(timeIntervalSince1970: launchTimestamp)
        let stateRoot = environment["CMUX_AGENT_HOOK_STATE_DIR"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".cmuxterm", isDirectory: true).path
        claimsDirectory = URL(fileURLWithPath: stateRoot, isDirectory: true)
            .appendingPathComponent("codex-fork-claims", isDirectory: true)
    }

    func wait() -> ChildSession? {
        var excludedSessionIDs: Set<String> = []
        while let child = Self.findForkedSession(
            parentSessionID: parentSessionID,
            sessionsRoot: sessionsRoot,
            launchedAt: launchedAt,
            ownerPID: ownerPID,
            excludingSessionIDs: excludedSessionIDs,
            fileManager: fileManager
        ) {
            if claim(child) { return child }
            excludedSessionIDs.insert(child.sessionID)
        }

        let signal = DispatchSemaphore(value: 0)
        let sources = directorySources { signal.signal() }
        guard !sources.isEmpty else { return nil }
        defer { sources.forEach { $0.cancel() } }

        let deadline = Date.now.addingTimeInterval(Self.watchTimeout)
        while Date.now < deadline {
            while let child = Self.findForkedSession(
                parentSessionID: parentSessionID,
                sessionsRoot: sessionsRoot,
                launchedAt: launchedAt,
                ownerPID: ownerPID,
                excludingSessionIDs: excludedSessionIDs,
                fileManager: fileManager
            ) {
                if claim(child) { return child }
                excludedSessionIDs.insert(child.sessionID)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // This semaphore only bridges DispatchSource filesystem events to
            // the short-lived CLI watcher; it does not guard mutable state.
            _ = signal.wait(timeout: .now() + min(remaining, 1))
        }
        while let child = Self.findForkedSession(
            parentSessionID: parentSessionID,
            sessionsRoot: sessionsRoot,
            launchedAt: launchedAt,
            ownerPID: ownerPID,
            excludingSessionIDs: excludedSessionIDs,
            fileManager: fileManager
        ) {
            if claim(child) { return child }
            excludedSessionIDs.insert(child.sessionID)
        }
        return nil
    }

    static func findForkedSession(
        parentSessionID: String,
        sessionsRoot: URL,
        launchedAt: Date,
        ownerPID: Int,
        excludingSessionIDs: Set<String> = [],
        fileManager: FileManager = .default
    ) -> ChildSession? {
        guard !parentSessionID.isEmpty, ownerPID > 0 else { return nil }
        let ownerRolloutPaths = Set(Self.openCodexRolloutPaths(pid: ownerPID).map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        })
        guard !ownerRolloutPaths.isEmpty else { return nil }
        let sessionsRootPath = sessionsRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let sessionsRootPrefix = sessionsRootPath.hasSuffix("/") ? sessionsRootPath : "\(sessionsRootPath)/"
        let candidateURLs = ownerRolloutPaths.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(sessionsRootPrefix),
                  url.pathExtension.lowercased() == "jsonl",
                  url.resolvingSymlinksInPath().path.hasPrefix(sessionsRootPrefix) else {
                return nil
            }
            return url
        }
        guard !candidateURLs.isEmpty else { return nil }
        let timestampFormatter = ISO8601DateFormatter()
        var candidates: [CodexForkSessionCandidate] = []
        for item in candidateURLs {
            guard let metadata = readMetadata(at: item, timestampFormatter: timestampFormatter),
                  metadata.parentSessionID == parentSessionID,
                  metadata.sessionID != parentSessionID,
                  !excludingSessionIDs.contains(metadata.sessionID) else {
                continue
            }
            let resourceValues = try? item.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey]
            )
            let fileDate = resourceValues?.creationDate
                ?? resourceValues?.contentModificationDate
                ?? .distantPast
            let candidateDate = metadata.timestamp ?? fileDate
            candidates.append(CodexForkSessionCandidate(
                sessionID: metadata.sessionID,
                parentSessionID: parentSessionID,
                transcriptPath: item.standardizedFileURL.path,
                createdAt: candidateDate
            ))
        }
        guard let match = CodexForkSessionMatcher().match(
            parentSessionID: parentSessionID,
            launchedAt: launchedAt,
            candidates: candidates,
            ownerRolloutPaths: ownerRolloutPaths
        ) else { return nil }
        return ChildSession(sessionID: match.sessionID, transcriptPath: match.transcriptPath)
    }

    private struct Metadata {
        let sessionID: String
        let parentSessionID: String?
        let timestamp: Date?
    }

    private static func readMetadata(
        at url: URL,
        timestampFormatter: ISO8601DateFormatter
    ) -> Metadata? {
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
        let timestamp = (payload["timestamp"] as? String).flatMap(timestampFormatter.date(from:))
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

    private func claim(_ child: ChildSession) -> Bool {
        guard !launchID.isEmpty,
              child.sessionID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return false
        }
        do {
            try fileManager.createDirectory(at: claimsDirectory, withIntermediateDirectories: true)
            pruneClaims()
            let claimURL = claimsDirectory.appendingPathComponent("\(child.sessionID).claim", isDirectory: false)
            let descriptor = open(claimURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            let bytes = Array(launchID.utf8)
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, bytes.count) == bytes.count
            }
            if !written { try? fileManager.removeItem(at: claimURL) }
            return written
        } catch {
            return false
        }
    }

    /// Releases this launch's claim after the synthetic SessionStart failed.
    func releaseClaim(for child: ChildSession) {
        guard !launchID.isEmpty else { return }
        let claimURL = claimsDirectory.appendingPathComponent("\(child.sessionID).claim", isDirectory: false)
        guard let contents = try? String(contentsOf: claimURL, encoding: .utf8),
              contents == launchID else {
            return
        }
        try? fileManager.removeItem(at: claimURL)
    }

    private func pruneClaims() {
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: claimsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func openCodexRolloutPaths(pid: Int) -> [String] {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return [] }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return [] }
        let actual = Int(used) / MemoryLayout<proc_fdinfo>.stride
        var paths: [String] = []
        for index in 0..<min(actual, fds.count) {
            guard fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fds[index].proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if path.hasSuffix(".jsonl") { paths.append(path) }
        }
        return paths
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
        var environment = ProcessInfo.processInfo.environment
        if let launchID = optionValue(commandArgs, name: "--fork-launch-id"), !launchID.isEmpty {
            environment[CodexForkSessionWatcher.launchIDEnvironmentKey] = launchID
        }
        if let ownerPID = optionValue(commandArgs, name: "--fork-owner-pid"), !ownerPID.isEmpty {
            environment["CMUX_CODEX_PID"] = ownerPID
        }
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
            let didBind = launchCodexForkSessionStart(
                child: child,
                parentSessionID: parentSessionID,
                environment: environment,
                client: client
            )
            if didBind { return }
            watcher.releaseClaim(for: child)
        }

        let clearParams: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "checkpoint_id": parentSessionID,
            "source": "agent-hook",
            "agent_session_ended": true,
        ]
        var clearStatus = "not-cleared"
        do {
            let result = try client.sendV2(method: "surface.resume.clear", params: clearParams)
            if result["cleared"] as? Bool == true { clearStatus = "cleared" }
        } catch {
            if let result = try? client.sendV2(method: "surface.resume.clear", params: clearParams),
               result["cleared"] as? Bool == true {
                clearStatus = "cleared"
            }
        }
        let title = String(localized: "agent.codex.fork.notice.title", defaultValue: "Agent fork")
        let body: String
        if clearStatus == "cleared" {
            body = String(
                localized: "agent.codex.fork.notice.body",
                defaultValue: "cmux could not identify the new fork session. Start the fork again from the parent pane."
            )
        } else {
            body = String(
                localized: "agent.codex.fork.notice.parentClearFailed.body",
                defaultValue: "cmux could not safely detach the parent session, so the fork was not started. Retry the fork from the parent pane."
            )
        }
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
    ) -> Bool {
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
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var payload: [String: Any] = [
                "session_id": child.sessionID,
                "forked_from_id": parentSessionID,
                "transcript_path": child.transcriptPath,
                "cwd": childEnvironment["PWD"] ?? FileManager.default.currentDirectoryPath,
                "hook_event_name": "SessionStart",
            ]
            if let launchID = childEnvironment[CodexForkSessionWatcher.launchIDEnvironmentKey] {
                payload["fork_launch_id"] = launchID
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                input.fileHandleForWriting.write(data)
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            let result = try? JSONSerialization.jsonObject(
                with: output.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
            return process.terminationStatus == 0
                && result?["cmux_fork_binding"] as? String == "bound"
        } catch {
            try? input.fileHandleForWriting.close()
            return false
        }
    }
}
