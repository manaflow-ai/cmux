import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

/// Exercises the production mobile chat adapter against a deterministic
/// host-shaped JSON-RPC transport. The fixture deliberately uses the same
/// wire payloads as the Mac service, while keeping provider transcripts out
/// of the test so this remains a transport contract test rather than a GUI
/// fixture.
@Suite
struct MobileChatEventSourceIntegrationTests {
    @Test
    func listsAndReconcilesClaudeCodexAndOpenCodeSessions() async throws {
        let sessions = Self.sessions
        let transport = MobileChatRPCTransport(sessions: sessions)
        let client = try Self.client(transport: transport)
        defer { Task { await client.disconnect() } }
        let source = MobileChatEventSource(client: client)

        let listed = try await source.sessions(workspaceID: nil)
        #expect(listed == sessions)
        #expect(listed.map { $0.agentKind.sourceName } == ["claude", "codex", "opencode"])

        for expected in sessions {
            let snapshot = try await source.session(sessionID: expected.id)
            #expect(snapshot == expected)

            let page = try await source.history(
                sessionID: expected.id,
                beforeSeq: nil,
                limit: 20
            )
            #expect(page.hasMore == false)
            #expect(page.messages.map(\.id) == ["\(expected.id)-message"])
            #expect(page.messages.first?.kind == .prose(ChatProse(text: "History for \(expected.agentKind.displayName)")))

            let controls = try await source.controls(sessionID: expected.id)
            #expect(controls.modelOptions.map(\.id) == ["model-a", "model-b"])
            var nextControls = controls
            nextControls.modelID = "model-b"
            nextControls.planMode = true
            let acknowledged = try await source.updateControls(nextControls, sessionID: expected.id)
            #expect(acknowledged.modelID == "model-b")
            #expect(acknowledged.planMode)

            try await source.send(
                text: "Continue \(expected.agentKind.displayName)",
                attachments: [],
                sessionID: expected.id
            )
            try await source.interrupt(sessionID: expected.id, hard: true)
            try await source.answer(
                optionIndex: 1,
                requestID: "request-\(expected.id)",
                sessionID: expected.id
            )
            try await source.review(
                action: .comment,
                sessionID: expected.id,
                messageID: "edit-\(expected.id)",
                filePath: "Sources/Review.swift",
                unifiedDiff: nil,
                lineNumber: 12,
                comment: "Please keep this branch covered."
            )
        }

        let requests = await transport.requests()
        #expect(requests.filter { $0.method == "mobile.chat.session" }.count == sessions.count)
        #expect(requests.filter { $0.method == "mobile.chat.history" }.count == sessions.count)
        #expect(requests.filter { $0.method == "mobile.chat.send" }.map(\.sessionID) == sessions.map(\.id))
        #expect(requests.filter { $0.method == "mobile.chat.interrupt" }.map(\.sessionID) == sessions.map(\.id))
        #expect(requests.filter { $0.method == "mobile.chat.interrupt" }.allSatisfy { $0.hard == true })
        #expect(requests.filter { $0.method == "mobile.chat.answer" }.map(\.sessionID) == sessions.map(\.id))
        #expect(requests.filter { $0.method == "mobile.chat.answer" }.allSatisfy { $0.optionIndex == 1 })
        #expect(requests.filter { $0.method == "mobile.chat.controls" }.count == sessions.count)
        #expect(requests.filter { $0.method == "mobile.chat.controls.update" }.count == sessions.count)
        // The generic controls API keeps explicit null semantics for a future
        // provider implementation, while normal prompt sends remain plain
        // text/attachment requests until a live provider-control path exists.
        #expect(requests.filter { $0.method == "mobile.chat.controls.update" }
            .allSatisfy { $0.reasoningEffortWasNull })
        #expect(requests.filter { $0.method == "mobile.chat.send" }
            .allSatisfy { !$0.hasControlsPayload })
        #expect(requests.filter { $0.method == "mobile.chat.review" }.map(\.sessionID) == sessions.map(\.id))
        #expect(requests.filter { $0.method == "mobile.chat.review" }.allSatisfy { $0.action == "comment" })
        #expect(requests.filter { $0.method == "mobile.chat.review" }.allSatisfy { $0.lineNumber == 12 })
    }

    @Test
    func sessionActionsUseTypedRenameDeleteAndExportRPCs() async throws {
        let transport = MobileChatRPCTransport(sessions: Self.sessions)
        let client = try Self.client(transport: transport)
        defer { Task { await client.disconnect() } }
        let source = MobileChatEventSource(client: client)

        try await source.rename(sessionID: "codex-session", title: "Network review")
        try await source.delete(sessionID: "claude-session")
        let export = try await source.exportTranscript(sessionID: "opencode-session")

        #expect(export.contains("History for OpenCode"))
        let requests = await transport.requests()
        #expect(requests.filter { $0.method == "mobile.chat.rename" }.map { $0.sessionID } == ["codex-session"])
        #expect(requests.filter { $0.method == "mobile.chat.delete" }.map { $0.sessionID } == ["claude-session"])
        #expect(requests.filter { $0.method == "mobile.chat.export" }.map { $0.sessionID } == ["opencode-session"])
    }

    @Test
    func sessionLaunchActionsDecodeTypedHostResults() async throws {
        let transport = MobileChatRPCTransport(sessions: Self.sessions)
        let client = try Self.client(transport: transport)
        defer { Task { await client.disconnect() } }
        let source = MobileChatEventSource(client: client)

        let fork = try await source.fork(sessionID: "codex-session")
        let resume = try await source.resume(sessionID: "claude-session")
        let reopen = try await source.reopen(sessionID: "opencode-session")

        #expect(fork.action == .fork)
        #expect(fork.parentSessionID == "codex-session")
        #expect(fork.terminalID == "codex-session-terminal")
        #expect(resume.action == .resume)
        #expect(reopen.action == .reopen)
        let requests = await transport.requests()
        #expect(requests.filter { $0.method == "mobile.chat.fork" }.map(\.sessionID) == ["codex-session"])
        #expect(requests.filter { $0.method == "mobile.chat.resume" }.map(\.sessionID) == ["claude-session"])
        #expect(requests.filter { $0.method == "mobile.chat.reopen" }.map(\.sessionID) == ["opencode-session"])
    }

    @Test
    func filtersChatMessageEventsBySessionAndPreservesProviderIdentity() async throws {
        let transport = MobileChatRPCTransport(sessions: Self.sessions)
        let client = try Self.client(transport: transport)
        defer { Task { await client.disconnect() } }
        let source = MobileChatEventSource(client: client)

        let stream = await source.events(sessionID: "codex-session")
        let nextFrame = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let ignored = ChatSessionEventFrame(
            sessionID: "claude-session",
            event: .stateChanged(.working(since: Date(timeIntervalSince1970: 10))),
            version: 8
        )
        let expected = ChatSessionEventFrame(
            sessionID: "codex-session",
            event: .stateChanged(.needsInput(since: Date(timeIntervalSince1970: 11))),
            version: 12
        )
        try await transport.emit(ignored)
        try await transport.emit(expected)

        let received = try #require(await nextFrame.value)
        #expect(received == expected.event)
        #expect(received == .stateChanged(.needsInput(since: Date(timeIntervalSince1970: 11))))

        let subscriptions = (await transport.requests()).filter {
            $0.method == "mobile.events.subscribe"
        }
        #expect(subscriptions.count == 1)
    }

    @Test
    func sessionEventsDeliversUnfilteredRevisionFramesForEveryProvider() async throws {
        let transport = MobileChatRPCTransport(sessions: Self.sessions)
        let client = try Self.client(transport: transport)
        defer { Task { await client.disconnect() } }
        let source = MobileChatEventSource(client: client)

        let stream = await source.sessionEvents()
        let expected = Self.sessions.map { session in
            ChatSessionEventFrame(
                sessionID: session.id,
                event: .descriptorChanged(session.withState(.idle, version: session.version + 1)),
                version: session.version + 1
            )
        }
        let receivedTask = Task {
            var iterator = stream.makeAsyncIterator()
            var received: [ChatSessionEventFrame] = []
            for _ in expected {
                if let frame = await iterator.next() {
                    received.append(frame)
                }
            }
            return received
        }
        for frame in expected {
            try await transport.emit(frame)
        }

        #expect(await receivedTask.value == expected)
    }

    private static let sessions: [ChatSessionDescriptor] = [
        ChatSessionDescriptor(
            id: "claude-session",
            agentKind: .claude,
            title: "Claude refactor",
            workspaceID: "workspace-1",
            terminalID: "terminal-claude",
            workingDirectory: "/repo/claude",
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 1),
            version: 4
        ),
        ChatSessionDescriptor(
            id: "codex-session",
            agentKind: .codex,
            title: "Codex tests",
            workspaceID: "workspace-1",
            terminalID: "terminal-codex",
            workingDirectory: "/repo/codex",
            state: .working(since: Date(timeIntervalSince1970: 2)),
            lastActivityAt: Date(timeIntervalSince1970: 2),
            version: 7
        ),
        ChatSessionDescriptor(
            id: "opencode-session",
            agentKind: .other("opencode"),
            title: "OpenCode docs",
            workspaceID: "workspace-1",
            terminalID: "terminal-opencode",
            workingDirectory: "/repo/opencode",
            state: .needsInput(since: Date(timeIntervalSince1970: 3)),
            lastActivityAt: Date(timeIntervalSince1970: 3),
            version: 9
        ),
    ]

    private static func client(transport: MobileChatRPCTransport) throws -> MobileCoreRPCClient {
        let route = try CmxAttachRoute(
            id: "mobile-chat-integration",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 59_321)
        )
        let runtime = MobileChatTestRuntime(
            transportFactory: MobileChatTransportFactory(transport: transport)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: "terminal-codex",
            macDeviceID: "mobile-chat-test-mac",
            macDisplayName: "Mobile Chat Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3_600),
            authToken: "attach-token"
        )
        return MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
    }
}

private struct MobileChatTestRuntime: MobileSyncRuntime {
    let transportFactory: any CmxByteTransportFactory
    let stackAccessTokenProvider: @Sendable () async throws -> String = { "stack-token" }
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "stack-token" }
    let rpcRequestTimeoutNanoseconds: UInt64 = 5 * 1_000_000_000
    let now: @Sendable () -> Date = Date.init
    let supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    let pairingRequestTimeoutNanoseconds: UInt64 = 5 * 1_000_000_000
    let supportsServerPushEvents = true
}

private struct MobileChatTransportFactory: CmxByteTransportFactory {
    let transport: MobileChatRPCTransport

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}

private struct CapturedChatRequest: Sendable, Equatable {
    let method: String
    let sessionID: String?
    let text: String?
    let optionIndex: Int?
    let hard: Bool?
    let action: String?
    let lineNumber: Int?
    let reasoningEffortWasNull: Bool
    let hasControlsPayload: Bool
}

private actor MobileChatRPCTransport: CmxByteTransport {
    private let sessions: [ChatSessionDescriptor]
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var capturedRequests: [CapturedChatRequest] = []
    private var isClosed = false

    init(sessions: [ChatSessionDescriptor]) {
        self.sessions = sessions
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed { return nil }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            try handle(payload: payload)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func requests() -> [CapturedChatRequest] {
        capturedRequests
    }

    func emit(_ frame: ChatSessionEventFrame) throws {
        let payload = try ChatWireCoding().encode(frame)
        let object = try JSONSerialization.jsonObject(with: payload)
        let event = try JSONSerialization.data(withJSONObject: [
            "kind": "event",
            "topic": "chat.message",
            "payload": object,
        ])
        deliver(try MobileSyncFrameCodec.encodeFrame(event))
    }

    private func handle(payload: Data) throws {
        let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let method = try #require(request["method"] as? String)
        let params = request["params"] as? [String: Any] ?? [:]
        capturedRequests.append(CapturedChatRequest(
            method: method,
            sessionID: params["session_id"] as? String,
            text: params["text"] as? String,
            optionIndex: params["option_index"] as? Int,
            hard: params["hard"] as? Bool,
            action: params["action"] as? String,
            lineNumber: params["line_number"] as? Int,
            reasoningEffortWasNull: params["reasoning_effort_id"] is NSNull,
            hasControlsPayload: params.keys.contains("controls")
        ))

        let result: Any
        switch method {
        case "mobile.chat.sessions":
            result = try jsonObject(MobileChatSessionsResponse(sessions: sessions))
        case "mobile.chat.session":
            let sessionID = try #require(params["session_id"] as? String)
            let session = try #require(sessions.first { $0.id == sessionID })
            result = try jsonObject(MobileChatSessionResponse(session: session))
        case "mobile.chat.history":
            let sessionID = try #require(params["session_id"] as? String)
            let session = try #require(sessions.first { $0.id == sessionID })
            let page = ChatHistoryPage(messages: [
                ChatMessage(
                    id: "\(session.id)-message",
                    seq: 1,
                    role: .agent,
                    timestamp: Date(timeIntervalSince1970: 4),
                    kind: .prose(ChatProse(text: "History for \(session.agentKind.displayName)"))
                )
            ], hasMore: false)
            result = try jsonObject(page)
        case "mobile.chat.controls", "mobile.chat.controls.update":
            let controls = ChatSessionControls(
                modelID: "model-a",
                modelOptions: [
                    ChatSessionControlOption(id: "model-a", displayName: "Model A"),
                    ChatSessionControlOption(id: "model-b", displayName: "Model B"),
                ],
                supportsPlanMode: true
            )
            if method.hasSuffix("update"), params["model_id"] as? String == "model-b" {
                var updated = controls
                updated.modelID = "model-b"
                updated.planMode = (params["plan_mode"] as? Bool) ?? false
                result = try jsonObject(ChatSessionControlsResponse(controls: updated))
            } else {
                result = try jsonObject(ChatSessionControlsResponse(controls: controls))
            }
        case "mobile.chat.export":
            let sessionID = try #require(params["session_id"] as? String)
            let session = try #require(sessions.first { $0.id == sessionID })
            result = ["text": "# \(session.agentKind.displayName)\n\nHistory for \(session.agentKind.displayName)"]
        case "mobile.chat.rename", "mobile.chat.delete":
            result = [:]
        case "mobile.chat.fork", "mobile.chat.resume", "mobile.chat.reopen":
            let sessionID = try #require(params["session_id"] as? String)
            let action = try #require(ChatSessionLaunchResult.Action(rawValue: method.replacingOccurrences(of: "mobile.chat.", with: "")))
            result = try jsonObject(ChatSessionLaunchResult(
                action: action,
                parentSessionID: sessionID,
                terminalID: "\(sessionID)-terminal"
            ))
        default:
            result = [:]
        }
        let response = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "ok": true,
            "result": result,
        ])
        deliver(try MobileSyncFrameCodec.encodeFrame(response))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try ChatWireCoding().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func deliver(_ frame: Data) {
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }
}
