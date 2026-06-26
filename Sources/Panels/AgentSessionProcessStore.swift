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
    private static let terminationEscalationInterval: DispatchTimeInterval = .seconds(3)

    func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) async throws -> AgentSessionStartedSession {
        guard sessions.isEmpty else {
            throw AgentSessionBridgeError.sessionAlreadyRunning
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
        let openCodeAuth = OpenCodeServerAuth(environment: launchEnvironment)
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
            stdin: stdin,
            inputWriter: inputWriter,
            openCodeAuthorizationHeader: openCodeAuth?.authorizationHeader
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

        if plan.provider != .opencode {
            emitStarted(session: running)
        }
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
            try await writeClaudeStreamJSON(text, to: session.inputWriter)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
    }

    func stop(sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        requestTermination(for: session)
    }

    func closeAll() {
        for session in sessions.values {
            requestTermination(for: session)
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
        requestTermination(for: session)
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func requestTermination(for session: AgentSessionRunningSession) {
        session.openCodeEventTask?.cancel()
        if session.process.isRunning {
            session.process.terminate()
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
                if session.process.isRunning {
                    _ = kill(session.process.processIdentifier, SIGKILL)
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
        Task {
            await session.inputWriter.close()
        }
        session.openCodeEventTask?.cancel()
        session.openCodeEventTask = nil
    }

    private func handleOutputLine(_ text: String, session: AgentSessionRunningSession, stream: String) {
        if session.providerID == .opencode {
            switch Self.openCodeProcessOutputDisposition(text: text, stream: stream) {
            case .serverURL(let baseURL):
                if session.openCodeBaseURL == nil {
                    session.openCodeBaseURL = baseURL
                    createOpenCodeSession(session)
                }
                return
            case .suppress:
                return
            case .emit:
                break
            }
        }

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

    static func openCodeProcessOutputDisposition(text: String, stream: String) -> OpenCodeProcessOutputDisposition {
        if let baseURL = OpenCodeServerClient.serverURL(from: text) {
            return .serverURL(baseURL)
        }
        if stream == "stdout" {
            return .suppress
        }
        return .emit
    }

    private func createOpenCodeSession(_ session: AgentSessionRunningSession) {
        guard !session.isOpenCodeSessionCreateInFlight,
              session.openCodeSessionID == nil,
              let baseURL = session.openCodeBaseURL else {
            return
        }
        session.isOpenCodeSessionCreateInFlight = true
        Task { @MainActor in
            do {
                let response = try await OpenCodeServerClient(
                    baseURL: baseURL,
                    authorizationHeader: session.openCodeAuthorizationHeader,
                    workingDirectory: session.workingDirectory
                ).postJSON(path: "session", body: [:])
                guard let id = response["id"] as? String, !id.isEmpty else {
                    throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
                }
                guard self.sessions[session.sessionId] === session else { return }
                session.openCodeSessionID = id
                session.isOpenCodeSessionCreateInFlight = false
                self.startOpenCodeEventStream(session)
                self.emitStarted(session: session)
            } catch {
                session.isOpenCodeSessionCreateInFlight = false
                guard let removedSession = self.sessions.removeValue(forKey: session.sessionId),
                      removedSession === session else {
                    return
                }
                self.emitActiveProviderStateIfNeeded()
                self.cancelSessionTasks(session)
                self.requestTermination(for: session)
                let message = (error as? AgentSessionBridgeError)?.localizedDescription
                    ?? String(
                        localized: "agentSession.opencode.error.sessionCreateFailed",
                        defaultValue: "OpenCode session could not be created."
                    )
                self.emitOutput(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    stream: "stderr",
                    text: "\(message)\n"
                )
                self.emitExit(
                    sessionId: session.sessionId,
                    providerID: session.providerID,
                    status: 1
                )
            }
        }
    }

    private func postOpenCodePrompt(_ text: String, session: AgentSessionRunningSession) async throws {
        guard let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            throw AgentSessionBridgeError.providerNotReady(session.providerID.displayName)
        }
        try await OpenCodeServerClient(
            baseURL: baseURL,
            authorizationHeader: session.openCodeAuthorizationHeader,
            workingDirectory: session.workingDirectory
        ).sendPrompt(text, sessionID: openCodeSessionID)
    }

    private func startOpenCodeEventStream(_ session: AgentSessionRunningSession) {
        guard session.openCodeEventTask == nil,
              let baseURL = session.openCodeBaseURL,
              let openCodeSessionID = session.openCodeSessionID else {
            return
        }
        let client = OpenCodeServerClient(
            baseURL: baseURL,
            authorizationHeader: session.openCodeAuthorizationHeader,
            workingDirectory: session.workingDirectory
        )
        let url = client.url(path: "event")
        let authorizationHeader = session.openCodeAuthorizationHeader
        let sessionId = session.sessionId

        session.openCodeEventTask = Task.detached(priority: .utility) { [weak self] in
            await OpenCodeServerClient.consumeEventStream(
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

    private func openCodeEventStreamEOFRequiresFailure(sessionId: String) -> Bool {
        Self.openCodeEventStreamEOFRequiresFailure(
            isCancelled: false,
            processIsRunning: sessions[sessionId]?.process.isRunning == true
        )
    }

    static func openCodeEventStreamEOFRequiresFailure(isCancelled: Bool, processIsRunning: Bool) -> Bool {
        !isCancelled && processIsRunning
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
