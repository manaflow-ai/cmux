import Foundation

final class AgentSessionRunningSession {
    let sessionId: String
    let providerID: AgentSessionProviderID
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
    let process: Process
    let stdin: Pipe
    let inputWriter: AgentSessionInputWriter
    let openCodeAuthorizationHeader: String?
    var codexAppServerSession: CodexAppServerSession?
    private var claudeStreamJSONAccumulator = ClaudeStreamJSONAccumulator()
    var openCodeBaseURL: URL?
    var openCodeSessionID: String?
    var isOpenCodeSessionCreateInFlight = false
    var stdoutReadTask: Task<Void, Never>?
    var stderrReadTask: Task<Void, Never>?
    var openCodeEventTask: Task<Void, Never>?
    var terminationEscalationTimer: DispatchSourceTimer?
    var pendingExitStatus: Int32?
    var drainedStreams: Set<String> = []
    private var stdoutBuffer = AgentSessionOutputLineBuffer()
    private var stderrBuffer = AgentSessionOutputLineBuffer()
    private var openCodeEventTextAccumulator = OpenCodeEventTextAccumulator()

    init(
        sessionId: String,
        providerID: AgentSessionProviderID,
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        process: Process,
        stdin: Pipe,
        inputWriter: AgentSessionInputWriter,
        openCodeAuthorizationHeader: String?
    ) {
        self.sessionId = sessionId
        self.providerID = providerID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.process = process
        self.stdin = stdin
        self.inputWriter = inputWriter
        self.openCodeAuthorizationHeader = openCodeAuthorizationHeader
    }

    func appendOutputData(_ data: Data, stream: String) -> [String] {
        if stream == "stdout" {
            return stdoutBuffer.append(data)
        }
        return stderrBuffer.append(data)
    }

    func flushBufferedOutput(stream: String) -> [String] {
        if stream == "stdout" {
            return stdoutBuffer.flush()
        }
        return stderrBuffer.flush()
    }

    func consumeClaudeStreamJSONLine(_ line: String) -> [String] {
        claudeStreamJSONAccumulator.consumeLine(line)
    }

    func claudeStreamJSONLineCompletesTurn(_ line: String) -> Bool {
        ClaudeStreamJSONAccumulator.completesAssistantTurn(line)
    }

    func consumeOpenCodeEvent(_ event: [String: Any], openCodeSessionID: String) -> [String] {
        openCodeEventTextAccumulator.consumeEvent(event, sessionID: openCodeSessionID)
    }

    func openCodeEventCompletesAssistantTurn(_ event: [String: Any], openCodeSessionID: String) -> Bool {
        OpenCodeEventTextAccumulator.completesAssistantTurn(event, sessionID: openCodeSessionID)
    }
}
