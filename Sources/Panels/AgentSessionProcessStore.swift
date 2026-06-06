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
    private static let closeTerminationGracePeriodNanoseconds: UInt64 = 3_000_000_000

    func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) throws -> AgentSessionStartedSession {
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
            openCodeAuthorizationHeader: openCodeAuth?.authorizationHeader
        )
        if plan.provider == .codex {
            running.codexAppServerSession = CodexAppServerSession(
                workingDirectory: workingDirectory,
                writeData: { data in
                    try stdin.fileHandleForWriting.write(contentsOf: data)
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

        installReadHandler(stdout.fileHandleForReading, sessionId: sessionId, stream: "stdout")
        installReadHandler(stderr.fileHandleForReading, sessionId: sessionId, stream: "stderr")
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
            try running.codexAppServerSession?.start()
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
            try codexAppServerSession.submit(text, permissionMode: permissionMode)
        case .claude:
            try writeClaudeStreamJSON(text, to: session.stdin)
        case .opencode:
            try await postOpenCodePrompt(text, session: session)
        }
    }

    func stop(sessionId: String) throws {
        guard let session = sessions[sessionId] else {
            throw AgentSessionBridgeError.sessionNotFound(sessionId)
        }
        requestTermination(for: session, escalateIfNeeded: false)
    }

    func closeAll() {
        for session in sessions.values {
            requestTermination(for: session, escalateIfNeeded: true)
        }
    }

    private func installReadHandler(_ fileHandle: FileHandle, sessionId: String, stream: String) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self,
                      let session = self.sessions[sessionId] else {
                    return
                }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    for text in session.flushBufferedOutput(stream: stream) {
                        self.handleOutputLine(text, session: session, stream: stream)
                    }
                    session.drainedStreams.insert(stream)
                    self.finishSessionIfExitedAndDrained(session)
                    return
                }
                for text in session.appendOutputData(data, stream: stream) {
                    self.handleOutputLine(text, session: session, stream: stream)
                }
            }
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
        requestTermination(for: session, escalateIfNeeded: false)
        emitExit(
            sessionId: session.sessionId,
            providerID: session.providerID,
            status: status
        )
    }

    private func requestTermination(for session: AgentSessionRunningSession, escalateIfNeeded: Bool) {
        session.openCodeEventTask?.cancel()
        if session.process.isRunning {
            session.process.terminate()
        }
        guard escalateIfNeeded,
              session.terminationEscalationTask == nil else {
            return
        }
        let process = session.process
        // Panel close gets a bounded grace period, then escalates so ignored SIGTERM cannot orphan agents.
        session.terminationEscalationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.closeTerminationGracePeriodNanoseconds)
            } catch {
                return
            }
            guard process.isRunning else {
                return
            }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cancelSessionTasks(_ session: AgentSessionRunningSession) {
        session.openCodeEventTask?.cancel()
        session.terminationEscalationTask?.cancel()
        session.terminationEscalationTask = nil
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
        if let baseURL = openCodeServerURL(from: text) {
            return .serverURL(baseURL)
        }
        if stream == "stdout" {
            return .suppress
        }
        return .emit
    }

    private static func openCodeServerURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
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
                let response = try await self.postJSON(
                    to: self.openCodeURL(baseURL: baseURL, path: "session", workingDirectory: session.workingDirectory),
                    body: [:],
                    authorizationHeader: session.openCodeAuthorizationHeader
                )
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
                self.requestTermination(for: session, escalateIfNeeded: false)
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

    private func writeClaudeStreamJSON(_ text: String, to stdin: Pipe) throws {
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
        try stdin.fileHandleForWriting.write(contentsOf: data)
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
