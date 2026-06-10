import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Codex transcript monitor leases
extension CMUXCLI {
    private static let codexMonitorLeaseDirectoryName = "codex-monitor-leases"
    private static let codexMonitorLeaseMaxAgeSeconds: TimeInterval = 4 * 60 * 60
    private static let codexMonitorRetiredLeaseMaxAgeSeconds: TimeInterval = 2 * 60
    private static let codexMonitorOwnerCheckIntervalSeconds: TimeInterval = 60
    private static let codexMonitorOwnerCheckTimeoutSeconds: TimeInterval = 1

    private func codexMonitorLeaseDirectory(env: [String: String]) -> URL {
        let statePath = NSString(
            string: agentHookStatePath(sessionStoreSuffix: "codex", env: env)
        ).expandingTildeInPath
        return URL(fileURLWithPath: statePath, isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.codexMonitorLeaseDirectoryName, isDirectory: true)
    }

    private func codexMonitorLeasePath(leaseId: String, env: [String: String]) -> String {
        return codexMonitorLeaseDirectory(env: env)
            .appendingPathComponent("\(leaseId).json", isDirectory: false)
            .path
    }

    private func writeCodexMonitorLease(_ record: CodexMonitorLeaseRecord, to path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    private func readCodexMonitorLease(path: String) -> CodexMonitorLeaseRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexMonitorLeaseRecord.self, from: data)
    }

    func createCodexMonitorLease(
        sessionId: String,
        turnId: String?,
        workspaceId: String,
        surfaceId: String?,
        env: [String: String]
    ) -> String? {
        let leaseId = UUID().uuidString.lowercased()
        let path = codexMonitorLeasePath(leaseId: leaseId, env: env)
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return nil }
        let record = CodexMonitorLeaseRecord(
            leaseId: leaseId,
            sessionId: normalizedSessionId,
            turnId: normalizedTurnId?.isEmpty == false ? normalizedTurnId : nil,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            createdAt: Date().timeIntervalSince1970,
            retiredAt: nil
        )
        try? pruneExpiredCodexMonitorLeases(env: env)
        do {
            try writeCodexMonitorLease(record, to: path)
            return path
        } catch {
            return nil
        }
    }

    func retireCodexMonitorLeases(
        sessionId: String,
        turnId: String?,
        preservingLeasePath: String? = nil,
        env: [String: String]
    ) {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else { return }

        let fileManager = FileManager.default
        let now = Date().timeIntervalSince1970
        let normalizedTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldMatchTurn = normalizedTurnId?.isEmpty == false
        let preservingPath = preservingLeasePath.map {
            URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL.path
        }
        let directory = codexMonitorLeaseDirectory(env: env)
        let targetPaths = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).map(\.path)

        for path in targetPaths {
            let standardizedPath = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
            guard preservingPath == nil || standardizedPath != preservingPath else {
                continue
            }
            guard var record = readCodexMonitorLease(path: path),
                  record.sessionId == normalizedSessionId,
                  !shouldMatchTurn || record.turnId == normalizedTurnId,
                  record.retiredAt == nil else {
                continue
            }
            record.retiredAt = now
            try? writeCodexMonitorLease(record, to: path)
        }
        try? pruneExpiredCodexMonitorLeases(env: env)
    }

    private func pruneExpiredCodexMonitorLeases(env: [String: String]) throws {
        let fileManager = FileManager.default
        let directory = codexMonitorLeaseDirectory(env: env)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let now = Date().timeIntervalSince1970
        let activeLeaseCutoff = now - Self.codexMonitorLeaseMaxAgeSeconds
        let retiredLeaseCutoff = now - Self.codexMonitorRetiredLeaseMaxAgeSeconds
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            guard let record = readCodexMonitorLease(path: url.path) else {
                continue
            }
            let activeLeaseExpired = record.createdAt < activeLeaseCutoff
            let retiredLeaseExpired = record.retiredAt.map { $0 < retiredLeaseCutoff } ?? false
            if activeLeaseExpired || retiredLeaseExpired {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func isCodexMonitorLeaseRetired(path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        guard let record = readCodexMonitorLease(path: path) else {
            return !FileManager.default.fileExists(atPath: path)
        }
        return record.retiredAt != nil
    }

    private func removeCodexMonitorLease(path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func codexMonitorOwnerState(workspaceId: String, surfaceId: String?, client: SocketClient) -> CodexMonitorOwnerState {
        guard client.connectionAppearsOpen() else { return client.isRelayBacked ? .unknown : .gone }
        guard let payload = try? client.sendV2(
            method: "surface.list",
            params: ["workspace_id": workspaceId],
            responseTimeout: Self.codexMonitorOwnerCheckTimeoutSeconds
        ) else {
            return .unknown
        }
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        guard let surfaceId, !surfaceId.isEmpty else { return surfaces.isEmpty ? .gone : .alive }
        let ownerFound = surfaces.contains { surface in
            (surface["id"] as? String) == surfaceId || (surface["ref"] as? String) == surfaceId
        }
        return ownerFound ? .alive : .gone
    }

    func startCodexTranscriptMonitor(
        sessionId: String,
        turnId: String?,
        transcriptPath: String?,
        cwd: String?,
        workspaceId: String,
        surfaceId: String?,
        leasePath: String?,
        env: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let monitorTelemetry: [String: Any] = [
            "has_lease": normalizedHookValue(leasePath) != nil,
            "has_turn_id": normalizedHookValue(turnId) != nil,
            "has_transcript": normalizedHookValue(transcriptPath) != nil,
            "has_surface_id": normalizedHookValue(surfaceId) != nil,
        ]
        telemetry.breadcrumb("codex-hook.monitor.start", data: monitorTelemetry)

        let executablePath = resolvedExecutableURL()?.path ?? args.first ?? "cmux"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var monitorArgs = [
            "hooks", "codex",
            "monitor",
            "--workspace",
            workspaceId,
            "--session",
            sessionId,
        ]
        if let surfaceId, !surfaceId.isEmpty {
            monitorArgs += ["--surface", surfaceId]
        }
        if let turnId, !turnId.isEmpty {
            monitorArgs += ["--turn", turnId]
        }
        if let transcriptPath, !transcriptPath.isEmpty {
            monitorArgs += ["--transcript", transcriptPath]
        }
        if let cwd, !cwd.isEmpty {
            monitorArgs += ["--cwd", cwd]
        }
        if let leasePath, !leasePath.isEmpty {
            monitorArgs += ["--lease", leasePath]
        }
        process.arguments = monitorArgs
        process.environment = env.merging(["CMUX_CLI_SENTRY_DISABLED": "1"], uniquingKeysWith: { _, new in new })
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            telemetry.breadcrumb("codex-hook.monitor.started", data: monitorTelemetry)
        } catch {
            telemetry.captureError(stage: "codex-monitor-start", error: error, data: monitorTelemetry)
        }
    }

    func runCodexTranscriptMonitor(commandArgs: [String], client: SocketClient) throws {
        let env = ProcessInfo.processInfo.environment
        let workspaceId = optionValue(commandArgs, name: "--workspace") ?? env["CMUX_WORKSPACE_ID"] ?? ""
        let surfaceId = optionValue(commandArgs, name: "--surface") ?? env["CMUX_SURFACE_ID"]
        let sessionId = optionValue(commandArgs, name: "--session")
            ?? env["CMUX_CODEX_SESSION_ID"]
            ?? env["CODEX_SESSION_ID"]
            ?? env["CMUX_AGENT_SESSION_ID"]
            ?? ""
        let turnId = optionValue(commandArgs, name: "--turn")
        var transcriptPath = optionValue(commandArgs, name: "--transcript")
        let leasePath = optionValue(commandArgs, name: "--lease")

        guard !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        defer { removeCodexMonitorLease(path: leasePath) }
        let deadline = Date().addingTimeInterval(4 * 60 * 60)
        var nextOwnerCheck = Date.distantPast
        var publishedUserInputCallIds = Set<String>()
        while Date() < deadline {
            if isCodexMonitorLeaseRetired(path: leasePath) {
                return
            }
            let now = Date()
            if now >= nextOwnerCheck {
                nextOwnerCheck = now.addingTimeInterval(Self.codexMonitorOwnerCheckIntervalSeconds)
                if codexMonitorOwnerState(workspaceId: workspaceId, surfaceId: surfaceId, client: client) == .gone {
                    return
                }
            }

            if transcriptPath == nil {
                transcriptPath = findCodexTranscriptPath(sessionId: sessionId, env: env)
            }

            if let currentTranscriptPath = transcriptPath {
                if let userInput = readCodexTranscriptUserInput(
                    path: currentTranscriptPath,
                    turnId: turnId,
                    excluding: publishedUserInputCallIds
                ) {
                    publishedUserInputCallIds.insert(userInput.callId)
                    publishCodexMonitorUserInput(
                        userInput,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        client: client
                    )
                }

                switch readCodexTranscriptFailure(
                    path: currentTranscriptPath,
                    turnId: turnId,
                    requireTerminalCompletion: true
                ) {
                case .failure(let failure):
                    publishCodexMonitorFailure(
                        failure,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        client: client
                    )
                    return
                case .healthy:
                    return
                case .pending:
                    break
                case .unavailable:
                    let unavailableTranscriptPath = currentTranscriptPath
                    transcriptPath = nil
                    if let resolvedTranscriptPath = findCodexTranscriptPath(sessionId: sessionId, env: env) {
                        transcriptPath = resolvedTranscriptPath
                        if resolvedTranscriptPath != unavailableTranscriptPath {
                            continue
                        }
                    }
                }
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            waitForCodexTranscriptChange(path: transcriptPath, leasePath: leasePath, timeout: min(30, remaining))
        }
    }

    private func publishCodexMonitorUserInput(
        _ userInput: CodexHookUserInputCandidate,
        workspaceId: String,
        surfaceId: String?,
        client: SocketClient
    ) {
        let subtitle = String(localized: "agent.codex.input.subtitle.waiting", defaultValue: "Waiting")
        let body = userInput.question ?? String(
            localized: "agent.codex.input.body.needsInput",
            defaultValue: "Codex is asking a question"
        )
        if let surfaceId, !surfaceId.isEmpty {
            let payload = "Codex|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
            _ = try? sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
        }
        let statusValue = String(localized: "agent.codex.input.status.needsInput", defaultValue: "Codex needs input")
        _ = try? sendV1Command(
            "set_status codex \(statusValue) --icon=bell.fill --color=#4C8DFF --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: client
        )
    }

    private func publishCodexMonitorFailure(
        _ failure: CodexHookFailureCandidate,
        workspaceId: String,
        surfaceId: String?,
        client: SocketClient
    ) {
        let summary = summarizeCodexHookFailureCandidate(failure)
        if let surfaceId, !surfaceId.isEmpty {
            let payload = "Codex|\(sanitizeNotificationField(summary.subtitle))|\(sanitizeNotificationField(summary.body))"
            _ = try? sendV1Command("notify_target \(workspaceId) \(surfaceId) \(payload)", client: client)
        }
        _ = try? sendV1Command(
            "set_status codex \(summary.statusValue) --icon=exclamationmark.triangle.fill --color=#FF453A --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: client
        )
    }

    private func waitForCodexTranscriptChange(path: String?, leasePath: String?, timeout: TimeInterval) {
        guard timeout > 0 else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var sources: [DispatchSourceFileSystemObject] = []

        func addFileSource(path: String?, eventMask: DispatchSource.FileSystemEvent) {
            guard let path, !path.isEmpty else { return }
            let expandedPath = NSString(string: path).expandingTildeInPath
            let fd = open(expandedPath, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: eventMask,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                semaphore.signal()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
        }

        addFileSource(path: path, eventMask: [.write, .extend, .delete, .rename])
        addFileSource(path: leasePath, eventMask: [.write, .delete, .rename])

        guard !sources.isEmpty else {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + timeout)
            return
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        sources.forEach { $0.cancel() }
    }

    func extractMessageText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

}
