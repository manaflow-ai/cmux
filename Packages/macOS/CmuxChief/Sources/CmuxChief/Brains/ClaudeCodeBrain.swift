public import CmuxHomeCore
public import Foundation

/// A ``ChiefBrain`` that drives Claude Code.
///
/// Each conversation gets one long-lived `claude -p` process speaking
/// stream-json both ways, started on its first turn and kept between turns.
/// A turn writes one user line; Stop sends an `interrupt` control request.
/// Permission requests arrive over stdio (`--permission-prompt-tool stdio`):
/// ``ChiefToolPolicy`` allows read-only calls and `cmux` commands, every
/// other call becomes an approval card. When the process dies, the next turn
/// starts a new one with `--resume` of the last session.
///
/// ```swift
/// let brain = ClaudeCodeBrain(configuration: .init(model: "claude-opus-5-5", effort: "high"))
/// for try await event in brain.run(request) { … }
/// ```
public actor ClaudeCodeBrain: ChiefBrain {
    /// How the brain launches Claude Code.
    public struct Configuration: Sendable, Equatable {
        /// The model id passed to `--model`.
        public var model: String
        /// The effort passed to `--effort`, nil for Claude Code's default.
        public var effort: String?
        /// Whether Claude Code may bypass permission prompts. Off by default.
        public var dangerouslySkipPermissions: Bool
        /// An explicit `claude` executable; nil looks it up on `PATH`.
        public var executableOverride: URL?
        /// Arguments added after the stream-json flags: by default the
        /// Chief's tool set, project settings only and no slash commands.
        public var extraArguments: [String]

        /// The tool set and settings a Chief runs with.
        public static let chiefArguments = [
            "--setting-sources", "project",
            "--disable-slash-commands",
            "--tools", "Bash,Read,Edit,Write,WebFetch,WebSearch,ToolSearch",
            "--permission-mode", "default",
        ]

        /// Creates a configuration.
        ///
        /// - Parameters:
        ///   - model: The model id.
        ///   - effort: The effort level, nil for the default.
        ///   - dangerouslySkipPermissions: Whether to bypass permission prompts.
        ///   - executableOverride: An explicit `claude` path.
        ///   - extraArguments: Arguments after the stream-json flags.
        public init(model: String, effort: String? = nil, dangerouslySkipPermissions: Bool = false,
                    executableOverride: URL? = nil,
                    extraArguments: [String] = Configuration.chiefArguments) {
            self.model = model
            self.effort = effort
            self.dangerouslySkipPermissions = dangerouslySkipPermissions
            self.executableOverride = executableOverride
            self.extraArguments = extraArguments
        }
    }

    /// How a process starts its session.
    enum SessionStart: Sendable, Equatable {
        /// A new session with this id (`--session-id`).
        case new(String)
        /// An existing session (`--resume`).
        case resume(String)
    }

    private let configuration: Configuration
    private let allowRules: ChiefAllowRules?
    private var conversations: [ConversationID: ClaudeConversation] = [:]
    /// Turns `run` handed out that have not reached their conversation yet.
    private let pendingTurns = ChiefPendingTurns()

    /// Creates a brain.
    ///
    /// - Parameter configuration: How to launch Claude Code.
    public init(configuration: Configuration, allowRules: ChiefAllowRules? = nil) {
        self.configuration = configuration
        self.allowRules = allowRules
    }

    nonisolated public func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChiefTurnEvent.self, throwing: (any Error).self)
        let token = UUID()
        let conversation = request.conversation
        let pendingTurns = pendingTurns
        // Registered before the stream is returned, so a Stop that beats the start task still finds it.
        pendingTurns.register(token, conversation: conversation)
        continuation.onTermination = { [weak self] _ in
            pendingTurns.stop(token)
            Task { await self?.existing(conversation)?.detach(token) }
        }
        Task { await self.startTurn(request, token: token, continuation: continuation) }
        return stream
    }

    public func respond(toApproval id: String, choice: String, conversation: ConversationID) async {
        await conversations[conversation]?.respond(toApproval: id, allow: ChiefToolPolicy.isAllow(choice))
    }

    public func interrupt(conversation: ConversationID) async {
        pendingTurns.stop(conversation: conversation)
        await conversations[conversation]?.interrupt()
    }

    public func shutdown() async {
        let all = Array(conversations.values)
        conversations = [:]
        for conversation in all { await conversation.shutdown() }
    }

    private func existing(_ id: ConversationID) -> ClaudeConversation? {
        conversations[id]
    }

    private func startTurn(_ request: ChiefTurnRequest, token: UUID,
                           continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation) async {
        let session: ClaudeConversation
        if let existing = conversations[request.conversation] {
            session = existing
        } else {
            session = ClaudeConversation(configuration: configuration, allowRules: allowRules)
            conversations[request.conversation] = session
        }
        await session.start(request, token: token, continuation: continuation, pending: pendingTurns)
    }

    /// The argument list of one `claude` process.
    ///
    /// - Parameters:
    ///   - configuration: Model, effort and extra arguments.
    ///   - session: A new session id or the session to resume.
    ///   - systemPrompt: The Chief's system prompt (`--append-system-prompt`).
    static func arguments(_ configuration: Configuration, session: SessionStart, systemPrompt: String) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--permission-prompt-tool", "stdio",
            "--model", configuration.model,
        ]
        if let effort = configuration.effort, !effort.isEmpty { arguments += ["--effort", effort] }
        switch session {
        case .new(let id): arguments += ["--session-id", id]
        case .resume(let id): arguments += ["--resume", id]
        }
        if !systemPrompt.isEmpty { arguments += ["--append-system-prompt", systemPrompt] }
        var extra = configuration.extraArguments
        if configuration.dangerouslySkipPermissions,
           let index = extra.firstIndex(of: "default"),
           index > 0, extra[index - 1] == "--permission-mode" {
            extra[index] = "bypassPermissions"
        }
        return arguments + extra
    }

    /// The content blocks of a turn's prompt: the text, then each image.
    static func promptContent(_ request: ChiefTurnRequest) -> [ChiefJSON] {
        var text = request.userText
        if let reply = request.replyContext, !reply.isEmpty {
            text = "(Replying to: \(ChiefToolPolicy.truncate(reply, to: 2000)))\n\n" + text
        }
        var content: [ChiefJSON] = [["type": "text", "text": .string(text)]]
        for path in request.attachmentPaths {
            guard let data = try? Data(contentsOf: path) else { continue }
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": .string(imageMediaType(path)),
                                       "data": .string(data.base64EncodedString())]])
        }
        return content
    }

    /// The media type of an image file, by extension.
    static func imageMediaType(_ path: URL) -> String {
        switch path.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

/// One conversation's Claude Code process and running turn.
actor ClaudeConversation {
    private typealias Continuation = AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation

    private let configuration: ClaudeCodeBrain.Configuration
    private let allowRules: ChiefAllowRules?
    private var process: ChiefLineProcess?
    private var generation = 0
    private var parser = ClaudeStreamParser()
    private var continuation: Continuation?
    private var token: UUID?
    private var approvals: [String: ChiefJSON] = [:]
    private var lastSession: String?
    private var brokenSessions: Set<String> = []
    private var controlCounter = 0
    /// The running turn's request and prompt, kept to retry a failed resume once.
    private var current: (request: ChiefTurnRequest, content: [ChiefJSON], resumed: Bool, retried: Bool)?
    private var turnOutput = false

    init(configuration: ClaudeCodeBrain.Configuration, allowRules: ChiefAllowRules? = nil) {
        self.configuration = configuration
        self.allowRules = allowRules
    }

    func start(_ request: ChiefTurnRequest, token: UUID, continuation: AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation,
               pending: ChiefPendingTurns) {
        // Claimed on this actor, so an `interrupt()` queued after a Stop always sees the turn.
        guard pending.claim(token) else {
            continuation.finish()
            return
        }
        if self.continuation != nil { interrupt() }
        self.continuation = continuation
        self.token = token
        turnOutput = false
        current = (request, ClaudeCodeBrain.promptContent(request), false, false)
        send(request)
    }

    private func send(_ request: ChiefTurnRequest) {
        guard var turn = current else { return }
        do {
            if process == nil {
                turn.resumed = try launch(request)
                current = turn
            }
        } catch {
            end(.failed(String(describing: error)))
            return
        }
        if let session = parser.sessionID { continuation?.yield(.session(session)) }
        let uuid = UUID().uuidString.lowercased()
        parser.beginTurn(echo: uuid)
        let line = ClaudeStreamParser.userMessage(uuid: uuid, content: turn.content).line
        // Queued, not written: a later EPIPE means the process died, and
        // `processEnded` reports it with stderr (and may retry a broken resume).
        if process?.write(line) != true {
            end(.failed(ChiefText.claudeStoppedBeforeReading))
        }
    }

    /// How the driver answers a `can_use_tool` request.
    enum PermissionDecision: Equatable {
        case allow, deny, ask
    }

    /// The answer to `tool` with `input`: deny without a running turn (nobody
    /// can answer, and an interrupted turn must not run more tools), allow
    /// what ``ChiefToolPolicy`` allows, ask about the rest.
    static func permissionDecision(
        tool: String,
        input: ChiefJSON,
        turnRunning: Bool,
        allowRules: ChiefAllowRules? = nil
    ) -> PermissionDecision {
        guard turnRunning else { return .deny }
        return ChiefToolPolicy.autoAllowsClaudeTool(tool, input: input, allowRules: allowRules) ? .allow : .ask
    }

    /// Starts `claude`; returns whether it resumes an earlier session.
    private func launch(_ request: ChiefTurnRequest) throws -> Bool {
        let environment = ChiefExecutableResolver.environment(request.environment,
                                                              overrides: ["CMUX_CLAUDE_HOOKS_DISABLED": "1"])
        guard let executable = ChiefExecutableResolver.resolve("claude", override: configuration.executableOverride,
                                                               environment: environment) else {
            throw ChiefBrainError.missingExecutable("claude")
        }
        let resumeID = [lastSession, request.resumeSession].compactMap { $0 }.first { !brokenSessions.contains($0) }
        let start: ClaudeCodeBrain.SessionStart = resumeID.map { .resume($0) } ?? .new(UUID().uuidString.lowercased())
        let arguments = ClaudeCodeBrain.arguments(configuration, session: start, systemPrompt: request.systemPrompt)
        let child = try ChiefLineProcess(executable: executable, arguments: arguments, environment: environment,
                                         workingDirectory: request.workingDirectory)
        generation += 1
        let mine = generation
        process = child
        switch start {
        case .new(let id), .resume(let id):
            parser = ClaudeStreamParser(sessionID: id)
            lastSession = id
        }
        controlCounter += 1
        child.write(ClaudeStreamParser.initializeRequest(id: "init-\(controlCounter)").line)
        let lines = child.lines
        Task { [weak self] in
            for await line in lines { await self?.handle(line, generation: mine) }
            await self?.processEnded(generation: mine)
        }
        if case .resume = start { return true }
        return false
    }

    private func handle(_ line: Data, generation: Int) {
        guard generation == self.generation else { return }
        for output in parser.consume(line) {
            // A retry may have replaced the process mid-batch.
            guard generation == self.generation else { return }
            switch output {
            case .event(let event):
                deliver(event)
            case .permission(let id, let tool, let input):
                let decision = Self.permissionDecision(
                    tool: tool,
                    input: input,
                    turnRunning: continuation != nil,
                    allowRules: allowRules
                )
                switch decision {
                case .allow, .deny:
                    write(ClaudeStreamParser.permissionResponse(requestID: id, allow: decision == .allow, input: input))
                case .ask:
                    approvals[id] = input
                    continuation?.yield(.approvalRequested(id: id, prompt: ChiefToolPolicy.claudePrompt(tool, input: input),
                                                           options: ChiefToolPolicy.approvalOptions(
                                                               command: tool == "Bash" ? input["command"]?.string : nil)))
                }
            case .stalePermission(let id, let input):
                // Asked by a stopped turn: never run it, never show it in the next turn.
                write(ClaudeStreamParser.permissionResponse(requestID: id, allow: false, input: input))
            case .unsupportedControl(let id, let subtype):
                write(ClaudeStreamParser.unsupportedResponse(requestID: id, subtype: subtype))
            }
        }
    }

    private func deliver(_ event: ChiefTurnEvent) {
        switch event {
        case .session(let id):
            lastSession = id
            continuation?.yield(event)
        case .failed(let message):
            if retryFreshSession(after: message) { return }
            end(.failed(message))
        case .finished:
            end(.finished)
        default:
            turnOutput = true
            continuation?.yield(event)
        }
    }

    /// A resumed session whose transcript is gone ("No conversation found")
    /// fails before any output: start a new session once and send the prompt again.
    private func retryFreshSession(after failure: String) -> Bool {
        guard failure.localizedCaseInsensitiveContains("no conversation found"),
              var turn = current, turn.resumed, !turn.retried, !turnOutput, let broken = lastSession else { return false }
        brokenSessions.insert(broken)
        lastSession = nil
        turn.retried = true
        turn.resumed = false
        current = turn
        stopProcess()
        send(turn.request)
        return true
    }

    private func processEnded(generation: Int) {
        guard generation == self.generation, let child = process else { return }
        process = nil
        parser.processExited()
        approvals = [:]
        guard continuation != nil else { return }
        let detail = child.stderrText
        if retryFreshSession(after: detail) { return }
        end(.failed(detail.isEmpty ? ChiefText.claudeExitedUnexpectedly : ChiefText.claudeExited(ChiefToolPolicy.truncate(detail, to: 600))))
    }

    func respond(toApproval id: String, allow: Bool) {
        guard let input = approvals.removeValue(forKey: id) else { return }
        write(ClaudeStreamParser.permissionResponse(requestID: id, allow: allow, input: input))
    }

    /// Stops the running turn: interrupts Claude Code, denies open approvals
    /// and ends the stream.
    func interrupt() {
        guard continuation != nil else { return }
        controlCounter += 1
        write(ClaudeStreamParser.interruptRequest(id: "int-\(controlCounter)"))
        denyApprovals()
        parser.abandonTurn()
        end(nil)
    }

    /// The consumer stopped reading turn `token` (cancelled); stop it if it still runs.
    func detach(_ token: UUID) {
        guard self.token == token else { return }
        interrupt()
    }

    func shutdown() {
        end(nil)
        approvals = [:]
        stopProcess()
    }

    private func stopProcess() {
        generation += 1
        process?.terminate()
        process = nil
        parser.processExited()
    }

    private func denyApprovals() {
        for (id, input) in approvals {
            write(ClaudeStreamParser.permissionResponse(requestID: id, allow: false, input: input))
        }
        approvals = [:]
    }

    private func write(_ json: ChiefJSON) {
        process?.write(json.line)
    }

    /// Ends the turn with `event` (nil just closes the stream).
    private func end(_ event: ChiefTurnEvent?) {
        let open = continuation
        continuation = nil
        token = nil
        current = nil
        if case .failed(let message)? = event {
            // An unknown model reads as one, with a pointer to Chief Settings.
            open?.yield(.failed(ChiefHarness.claude.failureMessage(message, model: configuration.model)))
        } else if let event {
            open?.yield(event)
        }
        open?.finish()
    }
}

/// Why a brain could not run a turn.
public enum ChiefBrainError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The agent CLI was not found on `PATH`.
    case missingExecutable(String)
    /// The agent CLI answered a request with an error.
    case protocolError(String)

    public var description: String {
        switch self {
        case .missingExecutable(let name):
            return ChiefText.missingExecutable(name)
        case .protocolError(let message):
            return message
        }
    }
}
