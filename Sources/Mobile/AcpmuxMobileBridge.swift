import CmuxAcpmux
import CmuxAgentChat
import Foundation
import Darwin

/// Main-actor bridge between the mobile RPC host and one acpmux connection.
///
/// The daemon owns durable session state. This object owns only the Mac-side
/// connection and a reducer-backed projection for the selected phone session;
/// the phone receives the backend-neutral chat wire values and never sees ACP
/// framing or a Unix socket path.
@MainActor
final class AcpmuxMobileBridge {
    static let eventTopic = "acpmux.chat.message"

    private let model: AcpmuxChatSessionModel
    private let coding = ChatWireCoding()
    private var didStart = false

    init(
        connector: any AcpmuxConnecting,
        workingDirectory: String? = nil
    ) {
        let model = AcpmuxChatSessionModel(
            connector: connector,
            sessionId: nil,
            workingDirectory: workingDirectory,
            attachLimit: 240,
            pageSize: 160
        )
        self.model = model
        model.onTranscriptChanged = { [weak self] in
            self?.emitSelectedSessionSnapshot()
        }
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        model.start()
    }

    func sessions() async throws -> [ChatSessionDescriptor] {
        try await waitUntilConnected()
        return model.sessions.map(makeDescriptor)
    }

    func session(sessionID: String) async throws -> ChatSessionDescriptor {
        try await selectIfNeeded(sessionID)
        return makeDescriptor(model.summary ?? model.sessions.first { $0.sessionId == sessionID })
    }

    func createSession(harness: String?, workingDirectory: String?) async throws -> String {
        try await waitUntilConnected()
        model.newSessionHarness = harness
        guard let sessionID = await model.createSession(harness: harness) else {
            throw AcpmuxMobileBridgeError.requestFailed("acpmux could not create a session")
        }
        _ = workingDirectory // The connector's default cwd is authoritative.
        return sessionID
    }

    func history(sessionID: String, beforeSeq: Int?) async throws -> ChatHistoryPage {
        try await selectIfNeeded(sessionID)
        if beforeSeq != nil {
            await model.loadOlder()
        }
        return ChatHistoryPage(
            messages: makeMessages(model.rows),
            hasMore: model.canLoadOlder
        )
    }

    func send(sessionID: String, text: String) async throws {
        try await selectIfNeeded(sessionID)
        model.send(text)
    }

    func cancel(sessionID: String) async throws {
        try await selectIfNeeded(sessionID)
        model.cancelTurn()
    }

    func answer(sessionID: String, optionIndex: Int) async throws {
        try await selectIfNeeded(sessionID)
        guard let permission = model.pendingPermission,
              permission.request.options.indices.contains(optionIndex) else {
            throw AcpmuxMobileBridgeError.requestFailed("No pending acpmux permission matches that option")
        }
        model.respond(
            to: permission,
            optionId: permission.request.options[optionIndex].optionId
        )
    }

    private func selectIfNeeded(_ sessionID: String) async throws {
        try await waitUntilConnected()
        guard !sessionID.isEmpty else {
            throw AcpmuxMobileBridgeError.requestFailed("Missing acpmux session id")
        }
        if model.sessionId != sessionID {
            await model.select(sessionId: sessionID)
        }
        guard model.sessionId == sessionID else {
            throw AcpmuxMobileBridgeError.requestFailed("acpmux session is unavailable")
        }
    }

    private func waitUntilConnected() async throws {
        startIfNeeded()
        for _ in 0..<250 {
            switch model.connectionState {
            case .connected:
                return
            case .failed(let message):
                throw AcpmuxMobileBridgeError.requestFailed(message)
            case .connecting:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw AcpmuxMobileBridgeError.requestFailed("acpmux connection timed out")
    }

    private func makeDescriptor(_ summary: AcpmuxSessionSummary?) -> ChatSessionDescriptor {
        guard let summary else {
            return ChatSessionDescriptor(
                id: model.sessionId ?? "acpmux-unknown",
                agentKind: .other("acpmux"),
                title: nil,
                state: .ended
            )
        }
        let state: ChatAgentState
        if model.sessionId == summary.sessionId, model.pendingPermission != nil {
            state = .needsInput(since: date(milliseconds: summary.updatedAt))
        } else if summary.isWorking || model.isWorking, model.sessionId == summary.sessionId {
            state = .working(since: date(milliseconds: summary.updatedAt))
        } else if summary.status == "closed" || summary.status == "disconnected" {
            state = .ended
        } else {
            state = .idle
        }
        return ChatSessionDescriptor(
            id: summary.sessionId,
            agentKind: .init(source: summary.harness ?? "acpmux"),
            title: summary.displayTitle,
            workspaceID: nil,
            terminalID: nil,
            workingDirectory: summary.cwd,
            state: state,
            lastActivityAt: date(milliseconds: summary.updatedAt),
            version: summary.lastSeq ?? 0
        )
    }

    private func makeMessages(_ rows: [TranscriptRow]) -> [ChatMessage] {
        var sequence = 0
        var messages: [ChatMessage] = []
        for row in rows {
            let timestamp = date(milliseconds: row.at)
            func append(_ role: ChatRole, _ kind: ChatMessageKind, suffix: String = "") {
                sequence += 1
                messages.append(
                    ChatMessage(
                        id: suffix.isEmpty ? row.id : "\(row.id)-\(suffix)",
                        seq: sequence,
                        role: role,
                        timestamp: timestamp,
                        kind: kind
                    )
                )
            }
            switch row.content {
            case .user(let message):
                append(.user, .prose(ChatProse(text: message.text)))
            case .assistant(let text, _):
                append(.agent, .prose(ChatProse(text: text)))
            case .activity(let group):
                for (index, item) in group.items.enumerated() {
                    switch item {
                    case .thought(let text):
                        append(.agent, .thought(ChatThought(text: text)), suffix: "thought-\(index)")
                    case .tool(let tool):
                        let status: ChatToolUse.Status = tool.status == "failed" ? .failed
                            : tool.isFinished ? .succeeded : .running
                        append(
                            .agent,
                            .toolUse(
                                ChatToolUse(
                                    toolName: tool.title,
                                    summary: tool.inputSummary ?? tool.title,
                                    inputDetail: tool.inputSummary,
                                    output: tool.output,
                                    status: status
                                )
                            ),
                            suffix: "tool-\(index)"
                        )
                    }
                }
            case .plan(let entries):
                let text = entries.map { "\($0.status == "completed" ? "✓" : "○") \($0.content)" }.joined(separator: "\n")
                append(.agent, .prose(ChatProse(text: text)), suffix: "plan")
            case .permission(let card):
                let resolution: ChatPermissionRequest.Resolution? = switch card.resolution {
                case .selected(_, let allowed): allowed ? .approved : .denied
                case .cancelled: .expired
                case nil: nil
                }
                let subject = card.request.toolCall?.title ?? "Tool action"
                append(
                    .agent,
                    .permissionRequest(
                        ChatPermissionRequest(
                            title: "Permission required",
                            subject: subject,
                            resolution: resolution,
                            options: card.request.options.enumerated().map {
                                ChatPermissionRequest.Option(index: $0.offset, label: $0.element.name)
                            }
                        )
                    )
                )
            case .turnSummary(let summary):
                let detail = summary.error ?? "Turn \(summary.status)"
                append(.system, .prose(ChatProse(text: detail)), suffix: "summary")
            case .typing:
                continue
            case .notice(let text):
                append(.system, .prose(ChatProse(text: text)), suffix: "notice")
            }
        }
        return messages
    }

    private func emitSelectedSessionSnapshot() {
        guard let sessionID = model.sessionId,
              MobileHostService.hasEventSubscribers(topic: Self.eventTopic) else { return }
        let messages = makeMessages(model.rows)
        let updated = ChatSessionEventFrame(
            sessionID: sessionID,
            event: .updated(messages)
        )
        emit(updated)
        let descriptor = makeDescriptor(model.summary)
        emit(
            ChatSessionEventFrame(
                sessionID: sessionID,
                event: .descriptorChanged(descriptor)
            )
        )
        emit(
            ChatSessionEventFrame(
                sessionID: sessionID,
                event: .stateChanged(descriptor.state)
            )
        )
    }

    private func emit(_ frame: ChatSessionEventFrame) {
        guard let data = try? coding.encode(frame),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else { return }
        MobileHostService.emitEvent(topic: Self.eventTopic, payload: payload)
    }

    private func date(milliseconds: Int64?) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds ?? 0) / 1_000)
    }

    private func date(milliseconds: Int64) -> Date {
        date(milliseconds: Optional(milliseconds))
    }
}

enum AcpmuxMobileBridgeError: Error, Sendable, Equatable {
    case requestFailed(String)
}

/// Builds an isolated acpmux connector for a cmux process. Tagged DEV apps use
/// their own daemon home; release apps reuse the user's normal acpmux daemon.
@MainActor
func makeAcpmuxMobileConnector() -> AcpmuxDaemonConnector {
    let fileManager = FileManager.default
    let processEnvironment = ProcessInfo.processInfo.environment
    let bundle = Bundle.main
    let bundleID = bundle.bundleIdentifier ?? "com.cmuxterm.app"
    let support = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
        .appendingPathComponent(bundleID, isDirectory: true)
    let environment = AcpmuxDaemonEnvironment.resolve(
        tag: processEnvironment["CMUX_TAG"],
        bundledExecutable: bundle.url(forResource: "acpmux", withExtension: nil, subdirectory: "bin"),
        applicationSupportDirectory: support,
        processEnvironment: processEnvironment,
        userHome: fileManager.homeDirectoryForCurrentUser,
        userID: getuid()
    )
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    return AcpmuxDaemonConnector(
        environment: environment,
        launcher: AcpmuxDaemonLauncher(
            userHome: fileManager.homeDirectoryForCurrentUser,
            baseEnvironment: processEnvironment
        ),
        clientName: "cmux-ios-bridge",
        clientVersion: version
    )
}
