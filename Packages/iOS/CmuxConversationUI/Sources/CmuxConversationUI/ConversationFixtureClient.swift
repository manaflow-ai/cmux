#if DEBUG
import CmuxConversation
import CryptoKit
import Foundation

/// Deterministic in-process host used only by DEBUG simulator UI verification.
/// It drives the same client/model/view path as production and exposes a small
/// set of scenario seeds so UI tests can cover approvals, questions, queues,
/// tool lifecycles and file diffs without a provider process.
public actor ConversationFixtureClient: ConversationArtifactClient {
    public enum Scenario: String, Sendable {
        case all
        case empty
        case emptyList = "empty-list"
        case approval
        case question
        case files
        case emptyFiles = "empty-files"
        case artifact
        case asyncQuestion = "async-question"
        case running
        case disconnected

        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "approval": self = .approval
            case "empty": self = .empty
            case "empty-list": self = .emptyList
            case "question": self = .question
            case "files": self = .files
            case "empty-files": self = .emptyFiles
            case "artifact": self = .artifact
            case "async-question": self = .asyncQuestion
            case "running": self = .running
            case "disconnected": self = .disconnected
            default: self = .all
            }
        }
    }

    private struct SessionState {
        var session: ConversationSession
        var items: [ConversationItem]
        var pendingRequests: [ConversationRequest]
        var queued: [ConversationQueueItem]
        var receipts: [ConversationReceipt]
        var cursor: ConversationCursor
        var isRunning: Bool
        var history: [ConversationEvent]
        var continuations: [UUID: AsyncThrowingStream<ConversationEvent, any Error>.Continuation]
    }

    private var sessions: [ConversationID: SessionState]
    private let scenario: Scenario
    private let capabilities: ConversationCapabilities

    /// Creates a fixture. The scenario can also be selected with
    /// `CMUX_UITEST_CONVERSATION_SCENARIO` in a simulator launch environment.
    public init(scenario: Scenario? = nil) {
        let environmentScenario = ProcessInfo.processInfo.environment["CMUX_UITEST_CONVERSATION_SCENARIO"]
        self.scenario = scenario ?? Scenario(rawValue: environmentScenario ?? "all")
        self.capabilities = ConversationCapabilities(
            protocolVersion: "fixture/1",
            features: ["turn/start", "turn/steer", "turn/interrupt", "approval", "question", "queue", "diff", "artifact", "configure"],
            models: ["fixture-model"],
            efforts: ["fast", "balanced", "thorough"],
            speeds: ["standard", "quick"],
            supportsResume: true
        )
        let seedSession = ConversationSession(
            id: ConversationID(rawValue: "fixture-codex"),
            provider: .codex,
            title: "Native conversation fixture",
            workspaceID: "fixture-workspace",
            directory: "/tmp/cmux-fixture",
            state: .ready,
            isPinned: true
        )
        let secondSession = ConversationSession(
            id: ConversationID(rawValue: "fixture-claude"),
            provider: .claudeCode,
            title: "Claude Code example",
            workspaceID: "fixture-workspace",
            directory: "/tmp/cmux-fixture",
            state: .ready
        )
        let thirdSession = ConversationSession(
            id: ConversationID(rawValue: "fixture-opencode"),
            provider: .openCode,
            title: "OpenCode example",
            workspaceID: "fixture-workspace",
            directory: "/tmp/cmux-fixture",
            state: .ready
        )
        self.sessions = [
            seedSession.id: SessionState(session: seedSession, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, isRunning: false, history: [], continuations: [:]),
            secondSession.id: SessionState(session: secondSession, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, isRunning: false, history: [], continuations: [:]),
            thirdSession.id: SessionState(session: thirdSession, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, isRunning: false, history: [], continuations: [:]),
        ]
    }

    public func listSessions() async throws -> [ConversationSession] {
        seedIfNeeded()
        if scenario == .emptyList { return [] }
        return sessions.values.map(\.session).sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        let id = ConversationID(rawValue: "fixture-\(UUID().uuidString.lowercased())")
        let session = ConversationSession(
            id: id,
            provider: request.provider,
            title: request.title ?? "New \(request.provider.rawValue) task",
            workspaceID: request.workspaceID,
            directory: request.directory,
            state: .ready
        )
        sessions[id] = SessionState(session: session, items: [], pendingRequests: [], queued: [], receipts: [], cursor: 0, isRunning: false, history: [], continuations: [:])
        return session
    }

    public func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot {
        seedIfNeeded()
        guard let state = sessions[sessionID] else { throw FixtureError.missingSession }
        return makeSnapshot(state)
    }

    public func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] {
        guard let state = sessions[sessionID] else { throw FixtureError.missingSession }
        return state.history.filter { $0.sequence > after }
    }

    public func events(sessionID: ConversationID, after: ConversationCursor) async -> AsyncThrowingStream<ConversationEvent, any Error> {
        seedIfNeeded()
        let (stream, continuation) = AsyncThrowingStream<ConversationEvent, any Error>.makeStream()
        guard var state = sessions[sessionID] else {
            continuation.finish(throwing: FixtureError.missingSession)
            return stream
        }
        for event in state.history where event.sequence > after { continuation.yield(event) }
        let token = UUID()
        state.continuations[token] = continuation
        sessions[sessionID] = state
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(sessionID: sessionID, token: token) }
        }
        if scenario == .disconnected { continuation.finish(throwing: FixtureError.disconnected) }
        return stream
    }

    public func execute(_ command: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        guard var state = sessions[command.sessionID] else { throw FixtureError.missingSession }
        let receipt: ConversationReceipt
        switch command.command {
        case .startTurn(let text, _, _):
            state.isRunning = true
            state = appendItem(state, kind: .message, role: "user", text: text)
            state = appendItem(state, kind: .reasoning, text: "Working through the request…")
            state = appendTool(state, name: "shell", input: .string("pwd"), output: nil, status: .running)
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .run, state: "running")
        case .queue(let text):
            let item = ConversationQueueItem(id: ConversationItemID(rawValue: "queue-\(UUID().uuidString)"), commandID: command.commandID, text: text, position: state.queued.count)
            state.queued.append(item)
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .queue, queue: state.queued)
        case .editQueued(let itemID, let text):
            if let index = state.queued.firstIndex(where: { $0.id == itemID }) { state.queued[index].text = text }
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .queue, queue: state.queued)
        case .cancelQueued(let itemID):
            state.queued.removeAll { $0.id == itemID }
            state.queued = state.queued.enumerated().map { index, item in var value = item; value.position = index; return value }
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .queue, queue: state.queued)
        case .steer(let text):
            state = appendItem(state, kind: .message, role: "user", text: text)
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
        case .interrupt:
            state.isRunning = false
            state = appendTool(state, name: "shell", input: .string("pwd"), output: .string("/tmp/cmux-fixture"), status: .success)
            state = appendItem(state, kind: .result, text: "Codex run stopped")
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .run, state: "stopped")
        case .answerQuestion(let requestID, let answers):
            let answeredRequest = state.pendingRequests.first(where: { $0.id == requestID })
            state.pendingRequests.removeAll { $0.id == requestID }
            let answerText = answers.compactMap { $0.text ?? $0.optionID }.joined(separator: ", ")
            state = appendItem(state, kind: .message, role: "user", text: "Answer received: \(answerText.isEmpty ? "selected" : answerText)")
            if scenario == .question, answeredRequest?.question?.index == 0 {
                state.pendingRequests = [questionRequest(generation: state.session.generation, index: 1)]
            }
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .request, request: nil)
        case .resolveApproval(let requestID, let decision):
            state.pendingRequests.removeAll { $0.id == requestID }
            state = appendItem(state, kind: .result, text: decision == .deny ? "Approval denied" : "Approved")
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
            state = appendEvent(state, kind: .request, request: nil)
        case .rename(let title):
            state.session.title = title
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
        case .setPinned(let pinned):
            state.session.isPinned = pinned
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
        case .setArchived(let archived):
            state.session.isArchived = archived
            state.session.state = archived ? .archived : .ready
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
        case .configure:
            receipt = makeReceipt(commandID: command.commandID, sessionID: command.sessionID, state: .applied, generation: state.session.generation)
        }
        state.receipts.append(receipt)
        state = appendEvent(state, kind: .receipt, receipt: receipt)
        sessions[command.sessionID] = state
        return receipt
    }

    public func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? {
        sessions[query.sessionID]?.receipts.last(where: { $0.id == query.commandID })
    }

    public func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? {
        sessions[sessionID]?.receipts.last(where: { $0.id == commandID })
    }

    private var didSeed = false

    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        seedInitialState(for: ConversationID(rawValue: "fixture-codex"))
    }

    private func seedInitialState(for sessionID: ConversationID) {
        guard var state = sessions[sessionID] else { return }
        if scenario != .empty {
            state = appendItem(state, kind: .message, role: "user", text: "Build a native conversation surface for all three providers.")
            state = appendItem(state, kind: .reasoning, text: "I’ll keep provider details behind the host contract.")
            state = appendItem(state, kind: .plan, text: "Inspect workspace → run tools → report changes", plan: ConversationPlan(text: "Inspect workspace → run tools → report changes", status: "In progress"))
            state = appendTool(state, name: "shell", input: .object(["command": .string("pwd")]), output: .string("/tmp/cmux-fixture"), status: .success)
            state = appendItem(state, kind: .result, text: "Workspace is ready.")
        }
        if scenario != .empty && scenario != .emptyFiles {
            let diff = ConversationDiff(path: "Sources/App.swift", text: "@@ -1,3 +1,4 @@\n import SwiftUI\n+import CmuxConversationUI\n\n struct App: View {", comparison: "last-turn")
            state = appendItem(state, kind: .files, text: nil, diff: diff)
        }
        switch scenario {
        case .approval, .all:
            if scenario == .approval { state.pendingRequests = [approvalRequest(generation: state.session.generation)] }
        case .question:
            state.pendingRequests = [questionRequest(generation: state.session.generation, index: 0)]
        case .asyncQuestion:
            state.pendingRequests = [ConversationRequest(id: ConversationRequestID(rawValue: "fixture-async-question"), generation: state.session.generation, kind: "input", question: ConversationQuestion(category: "Follow-up", prompt: "Add any context for this task", options: [], allowsCustomAnswer: true))]
        case .files, .emptyFiles, .empty, .emptyList: break
        case .artifact: 
            let payload = Data("cmux fixture artifact\n".utf8)
            let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let artifact = ConversationArtifact(artifactID: "fixture-artifact", fileName: "report.txt", mediaType: "text/plain", byteCount: Int64(payload.count), sha256: hash)
            state = appendItem(state, kind: .artifact, text: nil, artifact: artifact)
        case .running:
            state.isRunning = true
            state = appendTool(state, name: "shell", input: .string("swift test"), output: nil, status: .running)
        case .disconnected:
            let payload = Data("cmux fixture artifact\n".utf8)
            let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            state = appendItem(state, kind: .artifact, text: nil, artifact: ConversationArtifact(artifactID: "fixture-artifact", fileName: "report.txt", mediaType: "text/plain", byteCount: Int64(payload.count), sha256: hash))
        }
        sessions[sessionID] = state
    }

    private func approvalRequest(generation: ConversationGeneration) -> ConversationRequest {
        ConversationRequest(id: ConversationRequestID(rawValue: "fixture-approval"), generation: generation, kind: "approval", approval: ConversationApproval(summary: "Run a command in this workspace?", command: "pwd", supportsAlwaysAllow: true))
    }

    private func questionRequest(generation: ConversationGeneration, index: Int) -> ConversationRequest {
        let options = [ConversationQuestionOption(id: "yes", label: "Yes", detail: "Continue with the plan"), ConversationQuestionOption(id: "no", label: "No", detail: "Stop here")]
        let prompt = index == 0 ? "Should I continue?" : "What should I call the result?"
        return ConversationRequest(id: ConversationRequestID(rawValue: "fixture-question-\(index)"), generation: generation, kind: "question", question: ConversationQuestion(category: "Plan", prompt: prompt, options: options, allowsCustomAnswer: true, index: index, total: 2))
    }

    private func makeSnapshot(_ state: SessionState) -> ConversationSnapshot {
        ConversationSnapshot(session: state.session, cursor: state.cursor, generation: state.session.generation, items: state.items, pendingRequests: state.pendingRequests, queued: state.queued, receipts: state.receipts, activeTurnID: state.isRunning ? ConversationTurnID(rawValue: "fixture-turn") : nil, isTurnRunning: state.isRunning, capabilities: capabilities)
    }

    private func makeReceipt(commandID: ConversationCommandID, sessionID: ConversationID, state: ConversationReceiptState, generation: ConversationGeneration) -> ConversationReceipt {
        ConversationReceipt(id: commandID, sessionID: sessionID, state: state, generation: generation)
    }

    private func appendItem(_ state: SessionState, kind: ConversationItemKind, role: String? = nil, text: String?, plan: ConversationPlan? = nil, diff: ConversationDiff? = nil, artifact: ConversationArtifact? = nil) -> SessionState {
        var state = state
        let item = ConversationItem(id: ConversationItemID(rawValue: "item-\(UUID().uuidString)"), sequence: state.cursor + 1, kind: kind, role: role, text: text, plan: plan, diff: diff, artifact: artifact)
        state.items.append(item)
        state = appendEvent(state, kind: .item, item: item)
        return state
    }

    private func appendTool(_ state: SessionState, name: String, input: ConversationJSONValue?, output: ConversationJSONValue?, status: ConversationToolStatus) -> SessionState {
        var state = state
        let tool = ConversationTool(toolID: "tool-\(UUID().uuidString)", name: name, input: input, output: output, status: status)
        let item = ConversationItem(id: ConversationItemID(rawValue: "item-\(UUID().uuidString)"), sequence: state.cursor + 1, kind: .tool, tool: tool)
        state.items.append(item)
        state = appendEvent(state, kind: .item, item: item)
        return state
    }

    private func appendEvent(_ state: SessionState, kind: ConversationEventKind, item: ConversationItem? = nil, request: ConversationRequest? = nil, queue: [ConversationQueueItem]? = nil, receipt: ConversationReceipt? = nil, state eventState: String? = nil) -> SessionState {
        var state = state
        state.cursor += 1
        let event = ConversationEvent(sessionID: state.session.id, sequence: state.cursor, generation: state.session.generation, kind: kind, item: item, request: request, queue: queue, receipt: receipt, state: eventState)
        state.history.append(event)
        for continuation in state.continuations.values { continuation.yield(event) }
        return state
    }

    private func removeContinuation(sessionID: ConversationID, token: UUID) {
        sessions[sessionID]?.continuations.removeValue(forKey: token)
    }

    public func artifactChunk(_ query: ConversationArtifactQuery) async throws -> ConversationArtifactChunk {
        guard query.sessionID.rawValue == "fixture-codex", query.artifactID == "fixture-artifact" else { throw FixtureError.missingSession }
        let payload = Data("cmux fixture artifact\n".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offset = Int(query.offset)
        let chunkSize = 8
        let end = min(payload.count, offset + chunkSize)
        let bytes = offset < payload.count ? payload.subdata(in: offset..<end) : Data()
        return ConversationArtifactChunk(artifactID: query.artifactID, fileName: "report.txt", offset: query.offset, totalBytes: UInt64(payload.count), sha256: hash, data: bytes)
    }

    public enum FixtureError: Error, LocalizedError, Sendable {
        case missingSession
        case disconnected
        public var errorDescription: String? {
            switch self { case .missingSession: "Fixture task not found"; case .disconnected: "Fixture disconnected" }
        }
    }
}
#endif
