import Foundation
import Darwin

@MainActor
final class AgentSessionProcessStore {
    var eventSink: (([String: Any]) -> Void)?
    var activeProviderSink: ((Bool) -> Void)? {
        didSet {
            emitActiveProviderStateIfNeeded()
        }
    }
    var hasActiveProviderSession: Bool {
        !sessions.isEmpty
    }
    private var sessions: [String: AgentSessionRunningSession] = [:]
    private var lastEmittedHasActiveProviderSession: Bool?
    private let openCodeServer: any OpenCodeServerServing
    private static let terminationEscalationInterval: DispatchTimeInterval = .seconds(3)

    init(openCodeServer: any OpenCodeServerServing = OpenCodeServerService()) {
        self.openCodeServer = openCodeServer
    }

    func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) async throws -> AgentSessionStartedSession {
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
        }
        if plan.provider == .opencode {
            return try await startOpenCodeSession(plan: plan, workingDirectory: workingDirectory)
        }
        let sessionId = UUID().uuidString
        let process = Process()
        let launchArguments = plan.arguments
        let launchEnvironment = plan.environment(overridingWorkingDirectory: workingDirectory)
        process.executableURL = plan.executableURL
        process.arguments = launchArguments
        process.environment = launchEnvironment
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .standardizedFileURL
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let inputWriter = AgentSessionInputWriter(fileHandle: stdin.fileHandleForWriting)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let running = AgentSessionRunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            executablePath: plan.executableURL.path,
            arguments: launchArguments,
            workingDirectory: workingDirectory,
            process: process,
            inputWriter: inputWriter,
            openCodeAuthorizationHeader: nil
        )
        if plan.provider == .codex {
            running.codexAppServerSession = CodexAppServerSession(
                workingDirectory: workingDirectory,
                writeData: { data in
                    try await inputWriter.write(data)
                },
                outputSink: { [weak self] stream, text in
                    self?.emitOutput(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        stream: stream,
                        text: text
                    )
                },
                activitySink: { [weak self] activity in
                    self?.emitActivity(
                        sessionId: sessionId,
                        providerID: plan.provider,
                        activity: activity
                    )
                },
                turnCompleteSink: { [weak self] in
                    self?.emitTurnComplete(
                        sessionId: sessionId,
                        providerID: plan.provider
                    )
                },
                failureSink: { [weak self] _ in
                    self?.failSession(sessionId: sessionId, status: 1)
                }
            )
        }
        sessions[sessionId] = running

        running.stdoutReadTask = makeReadTask(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        running.stderrReadTask = makeReadTask(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                session.pendingExitStatus = process.terminationStatus
                self.finishSessionIfExitedAndDrained(session)
            }
        }

        do {
            try process.run()
            emitActiveProviderStateIfNeeded()
            try await running.codexAppServerSession?.start()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            running.openCodeEventTask?.cancel()
            sessions.removeValue(forKey: sessionId)
            emitActiveProviderStateIfNeeded()
            throw error
        }

        emitStarted(session: running)
        return AgentSessionStartedSession(sessionId: sessionId)
    }

    func writeLine(
        sessionId: String,
        permissionMode: AgentSessionPermissionMode = .standard,
        text: String
    ) async throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }

        switch session.providerID {
        case .codex:
            guard let codexAppServerSession = session.codexAppServerSession else {
                throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
            }
            try await codexAppServerSession.submit(text, permissionMode: permissionMode)
        case .claude:
            guard let inputWriter = session.inputWriter else {
                throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
            }
            try await writeClaudeStreamJSON(text, to: inputWriter)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
    }

    func stop(sessionId: String) async throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        if session.providerID == .opencode {
            await stopOpenCodeSession(session, status: 0)
            return
        }
        requestTermination(for: session)
    }

    func closeAll() {
        for session in Array(sessions.values) {
            if session.providerID == .opencode {
                sessions.removeValue(forKey: session.sessionId)
                cancelSessionTasks(session)
                scheduleOpenCodeServerLeaseRelease(for: session)
            } else {
                requestTermination(for: session)
            }
        }
        emitActiveProviderStateIfNeeded()
    }

    private func startOpenCodeSession(
        plan: AgentSessionLaunchPlan,
        workingDirectory: String?
    ) async throws -> AgentSessionStartedSession {
        let sessionId = UUID().uuidString
        let connection = try await openCodeServer.acquireConnection(plan: plan)
        let running = AgentSessionRunningSession(
            sessionId: sessionId,
            providerID: plan.provider,
            executablePath: plan.executableURL.path,
            arguments: plan.arguments,
            workingDirectory: workingDirectory,
            process: nil,
            inputWriter: nil,
            openCodeAuthorizationHeader: connection.authorizationHeader,
            holdsOpenCodeServerLease: true
        )
        running.openCodeBaseURL = connection.baseURL
        sessions[sessionId] = running

        do {
            let response = try await postJSON(
                to: openCodeURL(
                    baseURL: connection.baseURL,
                    path: "session",
                    workingDirectory: workingDirectory
                ),
                body: [
                    "metadata": [
                        "cmuxAgentSessionId": sessionId,
                    ],
                ],
                authorizationHeader: connection.authorizationHeader
            )
            guard let openCodeSessionID = response["id"] as? String,
                  !openCodeSessionID.isEmpty else {
                throw AgentSessionBridgeError.providerNotReady(plan.provider.displayName)
            }
            guard sessions[sessionId] === running else {
                throw AgentSessionBridgeError.sessionNotFound(sessionId)
            }
            running.openCodeSessionID = openCodeSessionID
            startOpenCodeEventStream(running)
            emitActiveProviderStateIfNeeded()
            emitStarted(session: running)
            return AgentSessionStartedSession(sessionId: sessionId)
        } catch {
            sessions.removeValue(forKey: sessionId)
            cancelSessionTasks(running)
            await releaseOpenCodeServerLease(for: running)
            emitActiveProviderStateIfNeeded()
            throw error
        }
    }

    private func makeReadTask(_ fileHandle: FileHandle, sessionId: String, stream: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let data: Data
                do {
                    data = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    data = Data()
                }

                await self?.consumeOutputData(data, sessionId: sessionId, stream: stream)
                if data.isEmpty {
                    return
                }
            }
        }
    }

    private func consumeOutputData(_ data: Data, sessionId: String, stream: String) {
        guard let session = sessions[sessionId] else {
            return
        }
        if data.isEmpty {
            for text in session.flushBufferedOutput(stream: stream) {
                handleOutputLine(text, session: session, stream: stream)
            }
            session.drainedStreams.insert(stream)
            finishSessionIfExitedAndDrained(session)
            return
        }
        for text in session.appendOutputData(data, stream: stream) {
            handleOutputLine(text, session: session, stream: stream)
        }
    }

    private func finishSessionIfExitedAndDrained(_ session: AgentSessionRunningSession) {
        guard let status = session.pendingExitStatus,
              session.drainedStreams.isSuperset(of: ["stdout", "stderr"]),
              sessions[session.sessionId] === session else {
            return
        }
        sessions.removeValue(forKey: session.sessionId)
        cancelSessionTasks(session)
        emitActiveProviderStateIfNeeded()
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func failSession(sessionId: String, status: Int32) {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            return
        }
        emitActiveProviderStateIfNeeded()
        cancelSessionTasks(session)
        if session.providerID == .opencode {
            scheduleOpenCodeServerLeaseRelease(for: session)
        } else {
            requestTermination(for: session)
        }
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func requestTermination(for session: AgentSessionRunningSession) {
        session.openCodeEventTask?.cancel()
        guard let process = session.process else { return }
        if process.isRunning {
            process.terminate()
        }
        installTerminationEscalationTimer(for: session)
    }

    private func installTerminationEscalationTimer(for session: AgentSessionRunningSession) {
        guard session.terminationEscalationTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + Self.terminationEscalationInterval,
            repeating: Self.terminationEscalationInterval
        )
        timer.setEventHandler { [weak self, session] in
            Task { @MainActor in
                guard let process = session.process else {
                    timer.cancel()
                    return
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    return
                }
                guard let self,
                      self.sessions[session.sessionId] === session else {
                    timer.cancel()
                    return
                }
                guard session.pendingExitStatus != nil else {
                    return
                }
                session.drainedStreams.formUnion(["stdout", "stderr"])
                self.finishSessionIfExitedAndDrained(session)
            }
        }
        session.terminationEscalationTimer = timer
        timer.resume()
    }

    private func cancelSessionTasks(_ session: AgentSessionRunningSession) {
        session.terminationEscalationTimer?.cancel()
        session.terminationEscalationTimer = nil
        session.stdoutReadTask?.cancel()
        session.stdoutReadTask = nil
        session.stderrReadTask?.cancel()
        session.stderrReadTask = nil
        if let inputWriter = session.inputWriter {
            Task {
                await inputWriter.close()
            }
        }
        session.openCodeEventTask?.cancel()
        session.openCodeEventTask = nil
    }

    private func stopOpenCodeSession(_ session: AgentSessionRunningSession, status: Int32) async {
        guard sessions.removeValue(forKey: session.sessionId) === session else { return }
        cancelSessionTasks(session)
        if let baseURL = session.openCodeBaseURL,
           let openCodeSessionID = session.openCodeSessionID {
            await deleteOpenCodeSession(
                baseURL: baseURL,
                openCodeSessionID: openCodeSessionID,
                workingDirectory: session.workingDirectory,
                authorizationHeader: session.openCodeAuthorizationHeader
            )
        }
        await releaseOpenCodeServerLease(for: session)
        emitActiveProviderStateIfNeeded()
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func scheduleOpenCodeServerLeaseRelease(for session: AgentSessionRunningSession) {
        guard session.holdsOpenCodeServerLease else { return }
        session.holdsOpenCodeServerLease = false
        Task {
            await openCodeServer.releaseConnection()
        }
    }

    private func releaseOpenCodeServerLease(for session: AgentSessionRunningSession) async {
        guard session.holdsOpenCodeServerLease else { return }
        session.holdsOpenCodeServerLease = false
        await openCodeServer.releaseConnection()
    }

    private func handleOutputLine(_ text: String, session: AgentSessionRunningSession, stream: String) {
        if stream == "stdout",
           let codexAppServerSession = session.codexAppServerSession {
            codexAppServerSession.consumeStdout(text)
            return
        }

        if stream == "stdout",
           session.providerID == .claude {
            let completesTurn = session.claudeStreamJSONLineCompletesTurn(text)
            for delta in session.consumeClaudeStreamJSONLine(text) {
                emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: stream,
                    text: delta
                )
            }
            if completesTurn {
                emitTurnComplete(
                    sessionId: session.sessionId,
                    providerID: session.providerID
                )
            }
            return
        }

        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: stream,
            text: text
        )
    }

    private func postOpenCodePrompt(_ text: String, session: AgentSessionRunningSession) async throws {
        guard let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
        }
        let url = openCodeURL(
            baseURL: baseURL,
            path: "session/\(openCodeSessionID)/prompt_async",
            workingDirectory: session.workingDirectory
        )
        _ = try await postJSON(
            to: url,
            body: [
                "parts": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ],
            authorizationHeader: session.openCodeAuthorizationHeader
        )
    }

    private func startOpenCodeEventStream(_ session: AgentSessionRunningSession) {
        guard session.openCodeEventTask == nil,
              let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            return
        }
        let url = openCodeURL(baseURL: baseURL, path: "event", workingDirectory: session.workingDirectory)
        let authorizationHeader = session.openCodeAuthorizationHeader
        let sessionId = session.sessionId

        session.openCodeEventTask = Task.detached(priority: .utility) { [weak self] in
            await Self.consumeOpenCodeEventStream(
                sessionId: sessionId,
                openCodeSessionID: openCodeSessionID,
                url: url,
                authorizationHeader: authorizationHeader,
                handleEvent: { event in
                    await self?.handleOpenCodeEvent(
                        event,
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                },
                shouldFailOnEOF: {
                    await self?.openCodeEventStreamEOFRequiresFailure(sessionId: sessionId) ?? false
                },
                failStream: {
                    await self?.failOpenCodeEventStream(
                        sessionId: sessionId,
                        openCodeSessionID: openCodeSessionID
                    )
                }
            )
        }
    }

    nonisolated private static func consumeOpenCodeEventStream(
        sessionId: String,
        openCodeSessionID: String,
        url: URL,
        authorizationHeader: String?,
        handleEvent: ([String: Any]) async -> Void,
        shouldFailOnEOF: () async -> Bool,
        failStream: () async -> Void
    ) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                throw AgentSessionBridgeError.providerNotReady(AgentSessionProviderID.opencode.displayName)
            }

            var parser = OpenCodeEventStreamParser()
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                for event in parser.consumeLine(line) {
                    await handleEvent(event)
                }
            }
            for event in parser.flush() {
                await handleEvent(event)
            }
            guard !Task.isCancelled,
                  await shouldFailOnEOF() else {
                return
            }
            await failStream()
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("agentSession.opencode.eventStream.failed error=\(error.localizedDescription)")
#endif
            await failStream()
        }
    }

    private func openCodeEventStreamEOFRequiresFailure(sessionId: String) -> Bool {
        Self.openCodeEventStreamEOFRequiresFailure(
            isCancelled: false,
            sessionIsActive: sessions[sessionId] != nil
        )
    }

    static func openCodeEventStreamEOFRequiresFailure(isCancelled: Bool, sessionIsActive: Bool) -> Bool {
        !isCancelled && sessionIsActive
    }

    private func failOpenCodeEventStream(sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }
        let message = String(
            localized: "agentSession.opencode.error.eventStreamFailed",
            defaultValue: "OpenCode event stream disconnected."
        )
        emitOutput(
            sessionId: session.sessionId,
            providerID: session.providerID,
            stream: "stderr",
            text: "\(message)\n"
        )
        failSession(sessionId: sessionId, status: 1)
    }

    private func handleOpenCodeEvent(_ event: [String: Any], sessionId: String, openCodeSessionID: String) {
        guard let session = sessions[sessionId],
              session.openCodeSessionID == openCodeSessionID else {
            return
        }

        let completesTurn = session.openCodeEventCompletesAssistantTurn(
            event,
            openCodeSessionID: openCodeSessionID
        )
        for output in session.consumeOpenCodeEvent(event, openCodeSessionID: openCodeSessionID) {
            emitOutput(
                sessionId: session.sessionId,
                providerID: session.providerID,
                stream: "stdout",
                text: output
            )
        }
        if completesTurn {
            emitTurnComplete(
                sessionId: session.sessionId,
                providerID: session.providerID
            )
        }
    }

    private func openCodeURL(baseURL: URL, path: String, workingDirectory: String?) -> URL {
        let url = path.split(separator: "/").reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let workingDirectory {
            components?.queryItems = [URLQueryItem(name: "directory", value: workingDirectory)]
        }
        return components?.url ?? url
    }

    private func deleteOpenCodeSession(
        baseURL: URL,
        openCodeSessionID: String,
        workingDirectory: String?,
        authorizationHeader: String?
    ) async {
        let url = openCodeURL(
            baseURL: baseURL,
            path: "session/\(openCodeSessionID)",
            workingDirectory: workingDirectory
        )
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    private func postJSON(
        to url: URL,
        body: [String: Any],
        authorizationHeader: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw AgentSessionBridgeError.providerNotReady("OpenCode")
        }
        guard !data.isEmpty else { return [:] }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        return decoded as? [String: Any] ?? [:]
    }

    private func writeClaudeStreamJSON(_ text: String, to inputWriter: AgentSessionInputWriter) async throws {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ]
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        try await inputWriter.write(data)
    }

    private func emitStarted(session: AgentSessionRunningSession) {
        eventSink?([
            "type": "provider.started",
            "sessionId": session.sessionId,
            "providerId": session.providerID.rawValue,
            "executablePath": session.executablePath,
            "arguments": session.arguments
        ])
    }

    private func emitOutput(
        sessionId: String,
        providerID: AgentSessionProviderID,
        stream: String,
        text: String
    ) {
        eventSink?([
            "type": "provider.output",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "stream": stream,
            "text": text
        ])
    }

    private func emitActivity(
        sessionId: String,
        providerID: AgentSessionProviderID,
        activity: [String: Any]
    ) {
        var event = activity
        event["type"] = "provider.activity"
        event["sessionId"] = sessionId
        event["providerId"] = providerID.rawValue
        eventSink?(event)
    }

    private func emitTurnComplete(
        sessionId: String,
        providerID: AgentSessionProviderID
    ) {
        eventSink?([
            "type": "provider.turnComplete",
            "sessionId": sessionId,
            "providerId": providerID.rawValue
        ])
    }

    private func emitExit(
        sessionId: String,
        providerID: AgentSessionProviderID,
        status: Int32
    ) {
        eventSink?([
            "type": "provider.exit",
            "sessionId": sessionId,
            "providerId": providerID.rawValue,
            "status": status
        ])
    }

    private func emitActiveProviderStateIfNeeded() {
        let hasActiveProviderSession = self.hasActiveProviderSession
        guard lastEmittedHasActiveProviderSession != hasActiveProviderSession else { return }
        lastEmittedHasActiveProviderSession = hasActiveProviderSession
        activeProviderSink?(hasActiveProviderSession)
    }
}
