#if DEBUG
import CmuxAgentChat
import CmuxMobileShell
import Foundation
import SwiftUI

/// Deterministic fixture for simulator screenshots and UI tests. It feeds the
/// production AgentChatModeView through the same typed source seam as a Mac,
/// so visual verification covers the real navigation, cards, and composer.
actor AgentChatPreviewSource: AgentChatSessionSource {
    private let clock = Date(timeIntervalSince1970: 1_735_689_600)
    private var descriptors: [ChatSessionDescriptor]
    private var transcripts: [String: [ChatMessage]]
    private var continuations: [UUID: AsyncStream<ChatSessionEventFrame>.Continuation] = [:]
    private var versions: [String: Int]

    init() {
        let claude = ChatSessionDescriptor(
            id: "preview-claude",
            agentKind: .claude,
            title: "Implement the authentication flow",
            workspaceID: "cmux-ios",
            terminalID: "terminal-claude",
            workingDirectory: "/Users/dev/cmux",
            state: .needsInput(since: clock),
            lastActivityAt: clock.addingTimeInterval(180),
            version: 4
        )
        let codex = ChatSessionDescriptor(
            id: "preview-codex",
            agentKind: .codex,
            title: "Review the networking changes",
            workspaceID: "cmux-ios",
            terminalID: "terminal-codex",
            workingDirectory: "/Users/dev/cmux",
            state: .working(since: clock.addingTimeInterval(90)),
            lastActivityAt: clock.addingTimeInterval(90),
            version: 3
        )
        let opencode = ChatSessionDescriptor(
            id: "preview-opencode",
            agentKind: .other("opencode"),
            title: "Polish the release notes",
            workspaceID: "cmux-docs",
            terminalID: "terminal-opencode",
            workingDirectory: "/Users/dev/docs",
            state: .idle,
            lastActivityAt: clock,
            version: 2
        )
        descriptors = [claude, codex, opencode]
        versions = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0.version) })
        transcripts = [
            claude.id: Self.claudeTranscript(clock: clock),
            codex.id: Self.codexTranscript(clock: clock),
            opencode.id: Self.openCodeTranscript(clock: clock),
        ]
    }

    nonisolated var supportsArtifacts: Bool { false }
    nonisolated var supportsArtifactFolders: Bool { false }

    func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        guard let workspaceID else { return descriptors }
        return descriptors.filter { $0.workspaceID == workspaceID }
    }

    func session(sessionID: String) async throws -> ChatSessionDescriptor {
        guard let descriptor = descriptors.first(where: { $0.id == sessionID }) else {
            throw PreviewError.missingSession
        }
        return descriptor
    }

    func sessionEvents() async -> AsyncStream<ChatSessionEventFrame> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let frames = await sessionEvents()
        return AsyncStream { continuation in
            let pump = Task {
                for await frame in frames {
                    guard frame.sessionID == sessionID else { continue }
                    continuation.yield(frame.event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }

    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        guard let messages = transcripts[sessionID] else { throw PreviewError.missingSession }
        let page = if let beforeSeq {
            Array(messages.filter { $0.seq < beforeSeq }.suffix(limit))
        } else {
            Array(messages.suffix(limit))
        }
        return ChatHistoryPage(messages: page, hasMore: page.first?.seq ?? 0 > 1)
    }

    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        guard transcripts[sessionID] != nil else { throw PreviewError.missingSession }
        let nextSeq = (transcripts[sessionID]?.map(\.seq).max() ?? 0) + 1
        let message = ChatMessage(
            id: "preview-user-\(nextSeq)",
            seq: nextSeq,
            role: .user,
            timestamp: Date(),
            kind: .prose(ChatProse(text: text.isEmpty ? "Attached files" : text))
        )
        transcripts[sessionID, default: []].append(message)
        emit(sessionID: sessionID, event: .appended([message]))
    }

    func steer(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        try await send(text: text, attachments: attachments, sessionID: sessionID)
    }

    func interrupt(sessionID: String, hard: Bool) async throws {
        guard let index = descriptors.firstIndex(where: { $0.id == sessionID }) else { throw PreviewError.missingSession }
        let descriptor = descriptors[index]
        descriptors[index] = descriptor.withState(.idle, version: bumpVersion(sessionID))
        emit(sessionID: sessionID, event: .stateChanged(.idle))
    }

    func answer(optionIndex: Int, sessionID: String) async throws {
        guard var messages = transcripts[sessionID] else { throw PreviewError.missingSession }
        guard let index = messages.lastIndex(where: { message in
            switch message.kind {
            case .permissionRequest(let request): return request.resolution == nil
            case .question(let question): return question.selectedOptionLabel == nil
            default: return false
            }
        }) else { return }
        let message = messages[index]
        let replacement: ChatMessage
        switch message.kind {
        case .permissionRequest(let request):
            let resolution: ChatPermissionRequest.Resolution = optionIndex == request.options.count - 1 ? .denied : .approved
            replacement = ChatMessage(
                id: message.id, seq: message.seq, role: message.role, timestamp: message.timestamp,
                kind: .permissionRequest(ChatPermissionRequest(
                    title: request.title, subject: request.subject, resolution: resolution,
                    options: request.options, scope: request.scope
                ))
            )
        case .question(let question):
            let label = question.options.indices.contains(optionIndex) ? question.options[optionIndex].label : "Answered"
            replacement = ChatMessage(
                id: message.id, seq: message.seq, role: message.role, timestamp: message.timestamp,
                kind: .question(ChatQuestion(
                    prompt: question.prompt, options: question.options,
                    selectedOptionLabel: label, questionID: question.questionID
                ))
            )
        default: return
        }
        messages[index] = replacement
        transcripts[sessionID] = messages
        emit(sessionID: sessionID, event: .updated([replacement]))
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(sessionID: String, event: ChatSessionEvent) {
        let version = bumpVersion(sessionID)
        let frame = ChatSessionEventFrame(sessionID: sessionID, event: event, version: version)
        for continuation in continuations.values { continuation.yield(frame) }
    }

    private func bumpVersion(_ sessionID: String) -> Int {
        let version = (versions[sessionID] ?? 0) + 1
        versions[sessionID] = version
        return version
    }

    private enum PreviewError: Error { case missingSession }

    private static func message(_ id: String, _ seq: Int, _ role: ChatRole, _ date: Date, _ kind: ChatMessageKind) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, timestamp: date, kind: kind)
    }

    private static func claudeTranscript(clock: Date) -> [ChatMessage] {
        [
            message("claude-1", 1, .user, clock, .prose(ChatProse(text: "Implement the authentication flow and add tests."))),
            message("claude-2", 2, .agent, clock.addingTimeInterval(4), .thought(ChatThought(text: "I will inspect the existing session boundary and preserve the current API."))),
            message("claude-3", 3, .agent, clock.addingTimeInterval(8), .toolUse(ChatToolUse(toolName: "Read", summary: "Read Sources/Auth/Session.swift", inputDetail: "Sources/Auth/Session.swift", output: "Loaded 184 lines", status: .succeeded, referencedPaths: ["Sources/Auth/Session.swift"]))),
            message("claude-4", 4, .agent, clock.addingTimeInterval(12), .permissionRequest(ChatPermissionRequest(title: "Claude wants to run", subject: "swift test --package-path Packages/Auth", scope: "Shell commands"))),
            message("claude-5", 5, .agent, clock.addingTimeInterval(14), .question(ChatQuestion(prompt: "Which authentication environment should I use?", options: [ChatQuestion.Option(label: "Local development", detail: "Use the local fixture server."), ChatQuestion.Option(label: "Staging", detail: "Use the shared staging environment.")], questionID: "claude-question-1"))),
        ]
    }

    private static func codexTranscript(clock: Date) -> [ChatMessage] {
        [
            message("codex-1", 1, .user, clock, .prose(ChatProse(text: "Review the networking changes and summarize risks."))),
            message("codex-2", 2, .agent, clock.addingTimeInterval(3), .thought(ChatThought(text: "I am comparing the reconnect path with the existing retry policy."))),
            message("codex-3", 3, .agent, clock.addingTimeInterval(8), .toolUse(ChatToolUse(toolName: "Search", summary: "Search for reconnect policy", inputDetail: "rg -n reconnect Packages/", output: "12 matches", status: .succeeded))),
            message("codex-4", 4, .agent, clock.addingTimeInterval(12), .terminal(ChatTerminalCapture(command: "swift test --filter Network", output: "Test Suite 'Network' passed", exitCode: 0, durationSeconds: 4.2))),
            message("codex-5", 5, .agent, clock.addingTimeInterval(16), .fileEdit(ChatFileEdit(filePath: "Sources/Network/RetryPolicy.swift", operation: .edit, additions: 8, deletions: 3, unifiedDiff: "@@ retry policy\n- let delay = 1\n+ let delay = min(8, attempt * 2)"))),
            message("codex-6", 6, .agent, clock.addingTimeInterval(20), .attachment(ChatAttachment(media: .file, displayName: "network-review.md"))),
            message("codex-7", 7, .agent, clock.addingTimeInterval(24), .webSearch(ChatWebSearch(query: "Swift networking retry guidance", sources: [
                ChatWebSearch.Source(title: "URLSession documentation", url: "https://developer.apple.com/documentation/foundation/urlsession", snippet: "Apple's URL loading system documentation."),
                ChatWebSearch.Source(title: "Retrying failed requests", url: "https://example.com/retries", snippet: "A short guide to bounded backoff."),
            ]))),
        ]
    }

    private static func openCodeTranscript(clock: Date) -> [ChatMessage] {
        [
            message("opencode-1", 1, .user, clock, .prose(ChatProse(text: "Polish the release notes for the next build."))),
            message("opencode-2", 2, .agent, clock.addingTimeInterval(5), .toolUse(ChatToolUse(toolName: "edit", summary: "Edit CHANGELOG.md", status: .succeeded, referencedPaths: ["CHANGELOG.md"]))),
            message("opencode-3", 3, .agent, clock.addingTimeInterval(9), .question(ChatQuestion(prompt: "Should I include the migration note?", options: [ChatQuestion.Option(label: "Include it"), ChatQuestion.Option(label: "Leave it out")], questionID: "opencode-question-1"))),
        ]
    }
}

/// Full-screen visual fixture for the production Agent Chat surface.
public struct AgentChatPreviewView: View {
    @State private var store = CMUXMobileShellStore.preview()
    private let source = AgentChatPreviewSource()

    public init() {}

    public var body: some View {
        AgentChatModeView(store: store, source: source)
    }
}
#endif
