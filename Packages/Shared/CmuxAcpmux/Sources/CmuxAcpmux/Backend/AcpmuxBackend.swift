public import CmuxConversation
import Foundation

/// A ``ConversationBackend`` for one acpmux daemon.
///
/// Speaks acpmux's protocol (ACP plus `_acpmux/*`) on byte streams from a
/// ``ConversationStreamOpening``: a Unix socket on the Mac, or relay lanes
/// from the iPhone. With `singleAttachment` (the iPhone), opening a
/// conversation closes the previous one, so exactly one session streams.
///
/// ```swift
/// let backend = AcpmuxBackend(opener: UnixSocketStreamOpener { await supervisor.socketPath }, clientName: "cmux-mac", singleAttachment: false)
/// ```
public final class AcpmuxBackend: ConversationBackend {
    private let connection: AcpmuxConnection
    private let opener: any ConversationStreamOpening
    private let singleAttachment: Bool

    /// Creates a backend.
    /// - Parameters:
    ///   - opener: Opens streams to the daemon's host.
    ///   - clientName: The name acpmux shows for this client.
    ///   - singleAttachment: Keep at most one conversation open.
    ///   - maximumBackoff: The longest wait between reconnect attempts.
    ///   - clock: Times request deadlines and reconnect backoff; injected so
    ///     tests control time.
    public init(opener: any ConversationStreamOpening, clientName: String, singleAttachment: Bool, maximumBackoff: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock()) {
        self.opener = opener
        self.singleAttachment = singleAttachment
        connection = AcpmuxConnection(opener: opener, clientName: clientName, clock: clock, maximumBackoff: maximumBackoff)
    }

    /// Reachability, starting with the current value.
    public func connectionStates() -> AsyncStream<BackendConnectionState> {
        let (s, c) = AsyncStream<BackendConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let task = Task { [connection] in
            for await state in await connection.states() { c.yield(state) }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
        return s
    }

    /// The live session list.
    public func conversationList() -> AsyncStream<[ConversationSummary]> {
        let (s, c) = AsyncStream<[ConversationSummary]>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task { [connection] in
            for await list in await connection.sessions() { c.yield(list) }
            c.finish()
        }
        c.onTermination = { _ in task.cancel() }
        return s
    }

    /// Opens a session's feed.
    /// - Parameters:
    ///   - id: The session.
    ///   - pageSize: How many of the newest events to load first.
    /// - Returns: The feed.
    public func open(_ id: ConversationID, pageSize: Int) async throws -> any ConversationFeed {
        if singleAttachment {
            for (other, feed) in await connection.openFeeds() where other != id.rawValue {
                await feed.close()
            }
        }
        if let existing = await connection.openFeeds()[id.rawValue] {
            await existing.close()
        }
        let feed = AcpmuxFeed(sessionID: id.rawValue, pageSize: pageSize, connection: connection)
        await connection.register(feed, for: id.rawValue)
        return feed
    }

    /// Creates a session; idempotent per the first message's client id.
    /// - Parameters:
    ///   - settings: Harness, model, effort, policy, mode, working directory.
    ///   - message: The first message (sent afterwards with ``perform(_:on:)``).
    /// - Returns: The session id.
    public func create(settings: ConversationSettings, firstMessage message: OutgoingMessage) async throws -> ConversationID {
        let client = try await connection.connectedClient()
        var mux: [String: JSONValue] = ["clientMessageId": .string("new-" + message.clientMessageID.rawValue)]
        if let v = settings.agent { mux["harness"] = .string(v) }
        if let v = settings.model { mux["model"] = .string(v) }
        if let v = settings.effort { mux["effort"] = .string(v) }
        if let v = settings.policy { mux["policy"] = .string(v) }
        var params: [String: JSONValue] = ["mcpServers": .array([]), "_meta": .object(["acpmux": .object(mux)])]
        if let cwd = settings.workingDirectory { params["cwd"] = .string(cwd) }
        let r = try await client.request("session/new", .object(params), timeout: .seconds(60))
        guard let id = r["sessionId"]?.stringValue else { throw ConversationBackendError.protocolViolation("session/new returned no sessionId") }
        if let mode = settings.mode {
            _ = try? await client.request("session/set_mode", .object(["sessionId": .string(id), "modeId": .string(mode)]))
        }
        return ConversationID(id)
    }

    /// Runs a command. A message returns once acpmux has it.
    /// - Parameters:
    ///   - command: The command.
    ///   - id: The session.
    public func perform(_ command: ConversationCommand, on id: ConversationID) async throws {
        let client = try await connection.connectedClient()
        let sid = JSONValue.string(id.rawValue)
        switch command {
        case let .send(m):
            var mux: [String: JSONValue] = ["clientMessageId": .string(m.clientMessageID.rawValue)]
            if m.steer { mux["steer"] = .bool(true) }
            if !m.attachments.isEmpty {
                mux["attachments"] = .array(m.attachments.map { a in
                    var d: [String: JSONValue] = ["uploadId": .string(a.uploadID), "name": .string(a.name), "mimeType": .string(a.mimeType), "size": .number(Double(a.size)), "sha256": .string(a.sha256)]
                    if let t = a.thumbnail { d["thumbnailUploadId"] = .string(t.uploadID) }
                    return .object(d)
                })
            }
            // The answer arrives when the turn ends; the outcome comes as events.
            try await client.fire("session/prompt", .object(["sessionId": sid, "prompt": .array([.object(["type": .string("text"), "text": .string(m.text)])]), "_meta": .object(["acpmux": .object(mux)])]))
        case .cancelTurn:
            try await client.notify("session/cancel", .object(["sessionId": sid]))
        case let .dequeue(cmid):
            _ = try await client.request("_acpmux/dequeue", .object(["sessionId": sid, "clientMessageId": .string(cmid.rawValue)]))
        case let .retry(cmid):
            try await client.fire("_acpmux/retry", .object(["sessionId": sid, "clientMessageId": .string(cmid.rawValue)]))
        case let .answerApproval(rid, option):
            _ = try await client.request("_acpmux/permission_respond", .object(["sessionId": sid, "permissionId": .string(rid), "optionId": .string(option)]))
        case let .setMode(mode):
            _ = try await client.request("session/set_mode", .object(["sessionId": sid, "modeId": .string(mode)]))
        case let .setModel(model):
            _ = try await client.request("session/set_model", .object(["sessionId": sid, "modelId": .string(model)]))
        case .stop:
            _ = try await client.request("_acpmux/kill", .object(["sessionId": sid]))
        case .delete:
            _ = try await client.request("_acpmux/kill", .object(["sessionId": sid, "purge": .bool(true)]))
        }
    }

    /// Uploads a file on its own stream, resuming where acpmux stopped receiving.
    /// - Parameters:
    ///   - file: The file.
    ///   - id: The session.
    /// - Returns: Bytes acpmux holds, as they arrive.
    public func upload(_ file: UploadFile, to id: ConversationID) -> AsyncThrowingStream<UInt64, any Error> {
        AcpmuxUploader(opener: opener).upload(file, sessionID: id.rawValue)
    }

    /// Stops the connection.
    public func shutdown() async {
        await connection.stop()
    }
}
