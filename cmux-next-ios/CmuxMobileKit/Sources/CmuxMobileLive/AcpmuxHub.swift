import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// The app's acpmux client for the connected Mac. It outlives links: each
/// new link binds a fresh `acpmux` channel, runs `initialize` and
/// `_acpmux/watch`, and re-attaches every open chat from its last seq.
@MainActor
@Observable
public final class AcpmuxHub {
    public private(set) var sessions: [String: AcpmuxSession] = [:]
    public private(set) var isReady = false
    /// A failure binding the channel (shown in diagnostics).
    public private(set) var lastError: String?
    /// The link the channel rides on (artifact previews open `file` channels on it).
    @ObservationIgnored public var macLink: (any MacLink)?

    @ObservationIgnored private var connection: AcpmuxConnection?
    /// Callers of `waitUntilReady` (a Feed answer whose Mac's link is opening).
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [String: WeakSource] = [:]
    /// Watch-level events for the Feed: `(sessionId, notification)`.
    @ObservationIgnored public var onWatchEvent: (@MainActor (AcpmuxHub.WatchEvent) -> Void)?
    /// Signs an Allow or an answer with the phone's approval key after Face ID
    /// (verify/phone-approvals.md); nil while this phone is not paired.
    @ObservationIgnored public var approver: Approver?
    /// The daemon run that approvals bind (`initialize` `_meta.acpmux.personInstance`).
    @ObservationIgnored private var personInstance: String?
    /// This phone's Full-access setting (Settings > Devices on the Mac) covers this connection
    /// (`initialize` `_meta.acpmux.fullAccess`; false when the Mac's acpmux does not say). The
    /// mode menus then offer the harness's Full access mode too; acpmux still decides each
    /// switch. acpmux sends no notice when the setting changes: a refusal turns it off here,
    /// and the next connection reads it again.
    public private(set) var fullAccess = false

    /// The phone's approval signer for the linked Mac.
    public struct Approver: Sendable {
        /// The phone's link device id, as the Mac paired it.
        public var phoneID: String
        /// The Mac's mobile device id.
        public var macDevice: String
        /// Asks for Face ID (`reason` is what the system sheet says) and returns
        /// the signer it unlocked. The payload, and so its expiry, is made only
        /// after Face ID returns, so a slow answer never expires on the way.
        public var authorize: @Sendable (_ reason: String) async throws -> Signer
        public var now: @Sendable () -> Date

        /// Signs one message with the unlocked approval key.
        public typealias Signer = @Sendable (_ message: Data) throws -> Data

        public init(phoneID: String, macDevice: String, now: @escaping @Sendable () -> Date = { Date() },
                    authorize: @escaping @Sendable (_ reason: String) async throws -> Signer) {
            self.phoneID = phoneID
            self.macDevice = macDevice
            self.authorize = authorize
            self.now = now
        }
    }

    /// The Mac's acpmux predates phone approvals (its prompts carry no
    /// `decisionNonce`): a paired phone's Allow cannot count there.
    public struct ApproverUnsupported: Error, Equatable {
        public init() {}
    }

    /// The user closed Face ID and the passcode: nothing was sent.
    public struct ApprovalCancelled: Error, Equatable {
        public init() {}
    }

    public enum WatchEvent: Sendable {
        case sessionChanged(AcpmuxSession, recordKind: String, seq: Int)
        case permissionPending(sessionID: String, permissionID: String, request: JSONValue)
        case permissionResolved(sessionID: String)
        /// Every session, as the watch reported them on (re)connecting.
        case sessionsLoaded([AcpmuxSession])
    }

    private struct WeakSource { weak var source: AcpmuxSessionSource? }

    public init() {}

    /// Binds a new `acpmux` channel (nil unbinds after a link drop).
    public func bind(_ channel: (any LinkChannel)?, requestTimeout: Duration = .seconds(20)) async {
        pumpTask?.cancel()
        if let old = connection { Task { await old.close() } }
        connection = nil
        isReady = false
        lastError = nil
        fullAccess = false
        lastError = nil
        for entry in sources.values { entry.source?.linkDown() }
        guard let channel else { return }
        let connection = AcpmuxConnection(channel: channel)
        self.connection = connection
        await connection.start()
        let notifications = connection.notifications
        pumpTask = Task { [weak self] in
            for await notification in notifications {
                guard self?.connection === connection else { return }
                self?.handle(notification)
            }
            guard !Task.isCancelled, let self, self.connection === connection else { return }
            self.connection = nil
            self.isReady = false
            self.fullAccess = false
            self.lastError = self.lastError ?? "acpmux channel closed"
            for entry in self.sources.values { entry.source?.linkDown() }
        }
        do {
            let initialized = try await connection.request("initialize", .object([
                "protocolVersion": .number(1),
                "clientInfo": .object(["name": .string("cmux-ios"), "version": .string("1")]),
                "clientCapabilities": .object([:]),
            ]), timeout: requestTimeout)
            personInstance = initialized["_meta"]?["acpmux"]?["personInstance"]?.stringValue
            fullAccess = initialized["_meta"]?["acpmux"]?["fullAccess"] == .bool(true)
            let watched = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true)], timeout: requestTimeout)
            guard !(await connection.isClosed), self.connection === connection else { return }
            var next: [String: AcpmuxSession] = [:]
            for value in watched {
                if let session = AcpmuxSession(value) { next[session.id] = session }
            }
            sessions = next
            isReady = true
            lastError = nil
            let waiters = readyWaiters
            readyWaiters = [:]
            for waiter in waiters.values { waiter.resume(returning: true) }
            log.info("acpmux ready, \(next.count, privacy: .public) sessions")
            for entry in sources.values { entry.source?.linkUp() }
            onWatchEvent?(.sessionsLoaded(Array(next.values)))
            await seedPending(connection, requestTimeout: requestTimeout)
            try Task.checkCancellation()
        } catch {
            guard self.connection === connection else { return }
            self.connection = nil
            isReady = false
            fullAccess = false
            lastError = LinkController.reason(error)
            for entry in sources.values { entry.source?.linkDown() }
            await connection.close()
            log.error("acpmux bind failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks that were already open before this connection watched: acpmux
    /// notifies `permission_pending` only for new ones, so read each waiting
    /// session's permission records and report those with no decision.
    private func seedPending(_ connection: AcpmuxConnection, requestTimeout: Duration) async {
        for session in sessions.values where session.pendingPermissions > 0 {
            guard !Task.isCancelled, self.connection === connection else { return }
            guard let page = try? await connection.request("_acpmux/events", .object([
                "sessionId": .string(session.id),
                "beforeSeq": .number(Double(session.lastSeq + 1)),
                "limit": .number(200),
                "kinds": .array([.string("permission_request"), .string("permission_decision")]),
            ]), timeout: requestTimeout) else { continue }
            let records = page["events"]?.arrayValue ?? []
            let decided = Set(records.compactMap { record -> String? in
                record["kind"]?.stringValue == "permission_decision" ? record["msg"]?["permissionId"]?.stringValue : nil
            })
            for record in records where record["kind"]?.stringValue == "permission_request" {
                guard let id = record["msg"]?["permissionId"]?.stringValue, !decided.contains(id),
                      let request = record["msg"]?["request"] else { continue }
                onWatchEvent?(.permissionPending(sessionID: session.id, permissionID: id, request: request))
            }
        }
    }

    /// Waits until a channel is bound and watched (`isReady`), for at most
    /// `timeout` on `clock`. False on timeout or cancellation.
    public func waitUntilReady(timeout: Duration, clock: any Clock<Duration>) async -> Bool {
        if isReady { return true }
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout)
            self?.resumeWaiter(id, false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isReady || Task.isCancelled {
                    continuation.resume(returning: isReady)
                } else {
                    readyWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(id, false) }
        }
    }

    /// The Mac's session is gone (another team, the Mac removed): nobody waits on it.
    public func cancelWaiters() {
        let waiters = readyWaiters
        readyWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: false) }
    }

    private func resumeWaiter(_ id: UUID, _ ready: Bool) {
        readyWaiters.removeValue(forKey: id)?.resume(returning: ready)
    }

    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return try await connection.request(method, params)
    }

    public func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return try await connection.request(method, params, timeout: timeout)
    }

    /// ``AcpmuxConnection/wholeList(_:_:timeout:)`` on the current connection.
    public func wholeList(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> [JSONValue] {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return try await connection.wholeList(method, params, timeout: timeout)
    }

    public func notify(_ method: String, _ params: JSONValue) async throws {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        try await connection.notify(method, params)
    }

    /// The chat source for an acpmux session (one per session).
    public func source(sessionID: String, summary: AgentSessionSummary) -> AcpmuxSessionSource {
        if let existing = sources[sessionID]?.source { return existing }
        let source = AcpmuxSessionSource(hub: self, sessionID: sessionID, summary: summary)
        sources[sessionID] = WeakSource(source: source)
        return source
    }

    /// `_acpmux/permission_respond`. Throws the server's refusal (a remote
    /// connection may deny or cancel; an allow needs the Mac's person proof).
    public func respond(sessionID: String, permissionID: String, optionID: String?, answers: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "permissionId": .string(permissionID)]
        if let optionID { params["optionId"] = .string(optionID) }
        if let answers { params["answers"] = answers }
        if let optionID, let meta = try await signedMeta(sessionID: sessionID, permissionID: permissionID,
                                                         optionID: optionID, answers: answers) {
            params["_meta"] = meta
        }
        _ = try await request("_acpmux/permission_respond", .object(params))
    }

    /// Answers a question with the harness-shaped reply, signed like an Allow.
    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer) async throws {
        let reply = try question.reply(answer)
        var params = try AcpmuxRecords.convert(reply.params, to: JSONValue.self)
        if case .object(var object) = params, let session = object["sessionId"]?.stringValue,
           let permission = object["permissionId"]?.stringValue, let option = object["optionId"]?.stringValue,
           let meta = try await signedMeta(sessionID: session, permissionID: permission, optionID: option,
                                           answers: object["answers"], reason: Self.answerReason(question, answer)) {
            object["_meta"] = meta
            params = .object(object)
        }
        _ = try await request("_acpmux/permission_respond", params)
    }

    /// `_meta` for an Allow or an answer signed with the approval key after
    /// Face ID; nil for a reject option (never signed), an unpaired phone or a
    /// prompt that is no longer pending (acpmux then refuses or not-founds it).
    func signedMeta(sessionID: String, permissionID: String, optionID: String, answers: JSONValue?,
                    reason answerReason: String? = nil) async throws -> JSONValue? {
        guard let approver else { return nil }
        let info = try await request("_acpmux/info", .object(["sessionId": .string(sessionID)]))
        guard let pending = info["pending"]?.arrayValue?.first(where: { $0["permissionId"]?.stringValue == permissionID }) else {
            return nil
        }
        let options = pending["request"]?["options"]?.arrayValue ?? []
        let kind = options.first { $0["optionId"]?.stringValue == optionID }?["kind"]?.stringValue ?? ""
        if kind.hasPrefix("reject") { return nil }
        // A prompt with no nonce comes from an acpmux before phone approvals: an unsigned
        // Allow would only be refused with advice that does not apply to a paired phone.
        guard let nonce = pending["decisionNonce"]?.stringValue,
              let instance = pending["personInstance"]?.stringValue ?? personInstance else { throw ApproverUnsupported() }
        let title = pending["request"]?["toolCall"]?["title"]?.stringValue ?? ""
        // The Face ID sheet names what is sent: the chosen answers, or the Mac's own title (review M1, L3).
        let reason = answers != nil ? (answerReason ?? "Send your answer to the agent") : Self.allowReason(title: title)
        let sign: Approver.Signer
        do {
            sign = try await approver.authorize(reason)
        } catch PhoneKeys.Failure.cancelled {
            throw ApprovalCancelled()
        }
        // The expiry starts once Face ID returned.
        let payload = ApprovalPayload(
            instance: instance, macDevice: approver.macDevice, approver: approver.phoneID,
            session: info["sessionId"]?.stringValue ?? sessionID, permission: permissionID, option: optionID, nonce: nonce,
            expiresAt: Int(approver.now().timeIntervalSince1970 + ApprovalPayload.lifetime), answers: answers)
        return payload.meta(signature: try sign(payload.message))
    }

    /// The Face ID reason of an answer: the labels (and free text) chosen, so
    /// the person approves what is sent, not what a notification said.
    nonisolated static func answerReason(_ question: AgentQuestion, _ answer: AgentQuestionAnswer) -> String {
        var parts: [String] = []
        for item in question.items {
            guard let selection = answer.selections[item.id] else { continue }
            parts += item.options.filter { selection.optionIDs.contains($0.id) }.map(\.label)
            if let other = selection.other { parts.append(other) }
        }
        guard !parts.isEmpty else { return "Send your answer to the agent" }
        return "Answer “\(cut(parts.joined(separator: ", "), 80))”"
    }

    /// The Face ID reason of an Allow: the Mac's own title, marked when cut.
    nonisolated static func allowReason(title: String) -> String {
        title.isEmpty ? "Allow the agent's request" : "Allow “\(cut(title, 80))”"
    }

    private nonisolated static func cut(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }

    /// Declines a question (its reject option). A phone may always decline,
    /// while an answer needs the Mac's person proof.
    public func decline(_ question: AgentQuestion) async throws {
        guard let reply = question.declineReply() else {
            throw AcpmuxConnection.RPCError(code: 0, message: "This question can't be declined", reason: nil)
        }
        let params = try AcpmuxRecords.convert(reply.params, to: JSONValue.self)
        _ = try await request("_acpmux/permission_respond", params)
    }

    /// acpmux refused a request for this phone's Full-access setting (`remote.full_access_required`:
    /// turned off on the Mac since this connection's `initialize`): every chat's menu hides the
    /// Full access mode again.
    func fullAccessRefused() {
        fullAccess = false
        for entry in sources.values { entry.source?.fullAccessChanged(false) }
    }

    private func handle(_ notification: AcpmuxConnection.Notification) {
        let params = notification.params
        let sessionID = params["sessionId"]?.stringValue
        switch notification.method {
        case "_acpmux/event":
            if let sessionID { sources[sessionID]?.source?.receive(record: params) }
        case "_acpmux/session_changed":
            guard let value = params["session"], let session = AcpmuxSession(value) else { return }
            sessions[session.id] = session
            let kind = params["recordKind"]?.stringValue ?? params["kind"]?.stringValue ?? ""
            let seq = Int(params["seq"]?.numberValue ?? 0)
            onWatchEvent?(.sessionChanged(session, recordKind: kind, seq: seq))
            if params["kind"]?.stringValue == "permission_resolved" { onWatchEvent?(.permissionResolved(sessionID: session.id)) }
            if params["kind"]?.stringValue == "purged" { sessions[session.id] = nil }
        case "_acpmux/permission_pending":
            guard let sessionID, let permissionID = params["permissionId"]?.stringValue, let request = params["request"] else { return }
            onWatchEvent?(.permissionPending(sessionID: sessionID, permissionID: permissionID, request: request))
        case "_acpmux/lagged":
            // Missed notifications: attached chats fill their gap, and watch runs again. The
            // chats first, before the next notification: a record after the dropped ones must
            // be held for the refill, not applied ahead of it.
            for entry in sources.values { entry.source?.refill() }
            Task { [weak self] in
                guard let self, let connection = self.connection else { return }
                _ = try? await connection.request("_acpmux/watch", .object(["enabled": .bool(true)]))
            }
        default:
            break
        }
    }
}

/// `AgentSessionSource` over acpmux: attach with the event stream, page
/// history back, then stream live records; intents become acpmux calls.
@MainActor
public final class AcpmuxSessionSource: AgentSessionSource {
    public private(set) var summary: AgentSessionSummary
    let sessionID: String
    private weak var hub: AcpmuxHub?
    private let records: AcpmuxRecords
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []
    private var replay: [AgentSessionEvent] = []
    private var lastSeq = 0
    private var attached = false
    private var attaching = false
    /// Records that arrive while attaching are applied after the attach page.
    private var held: [JSONValue] = []
    private var questions: [String: AgentQuestion] = [:]
    /// The most records one history read returns.
    static let pageSize = 400
    /// The open's byte cap, as the Mac's agent pane opens: a long chat draws its newest records
    /// after one small read. It used to read 2000 records in five round trips first (1.3-4.3 MB
    /// on the Mac's long chats), and a page that timed out threw the whole read away.
    static let openBytes = 128 * 1024
    /// Each older page's byte cap (``loadEarlierHistory()``, as the reader scrolls up).
    static let olderBytes = 256 * 1024
    /// The most reads one scroll up makes looking for a prompt to start its page at.
    static let maxEarlierReads = 8
    /// The records a chat shows: acpmux's `transcript`, and by name the queue changes
    /// (Edit queued prompt, Move up / down, a held queue) that an older Mac's
    /// `transcript` leaves out, so the queue rows follow the Mac's queue; and Claude Code's API
    /// retries (a harness record, never `transcript`), so a retrying turn says so.
    static let chatKinds: JSONValue = .array(
        ["transcript", "queue_updated", "queue_order", "queue_paused", "queue_resumed", "claude.system.api_retry"].map { .string($0) })

    init(hub: AcpmuxHub, sessionID: String, summary: AgentSessionSummary) {
        self.hub = hub
        self.sessionID = sessionID
        self.summary = summary
        records = AcpmuxRecords(sessionID: sessionID)
        if hub.isReady { linkUp() }
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        // What this source already has is history to a new reader: one change, drawn in place.
        if !replay.isEmpty { continuation.yield(.batch(replay)) }
        continuations.append(continuation)
        return stream
    }

    public func send(_ intent: AgentClientIntent) {
        guard let hub else { return }
        let session = JSONValue.string(sessionID)
        Task {
            do {
                switch intent {
                case .prompt(let text, let attachments, let steer, let promptID, let resend):
                    let blocks: [JSONValue]
                    do {
                        blocks = try await self.promptBlocks(text: text, attachments: attachments, hub: hub)
                    } catch {
                        self.emit(.promptNotSent(text: text, attachments: attachments, promptID: promptID,
                                                 reason: AcpmuxSessionSource.message(error)))
                        return
                    }
                    // acpmux runs each promptId once; `resend` also checks the session log.
                    let meta: JSONValue = .object(["acpmux": .object([
                        "promptId": .string(promptID), "steer": .bool(steer), "resend": .bool(resend),
                    ])])
                    do {
                        _ = try await hub.request("session/prompt", .object([
                            "sessionId": session, "prompt": .array(blocks), "_meta": meta,
                        ]))
                    } catch let error as LinkError {
                        // Maybe never reached the Mac: the draft comes back with its id, so a resend
                        // runs at most once, and it leaves again if the transcript shows it ran.
                        self.emit(.promptNotSent(text: text, attachments: attachments, promptID: promptID,
                                                 reason: AcpmuxSessionSource.message(error)))
                    }
                case .retryFailedTurn:
                    _ = try await hub.request("_acpmux/retry", .object(["sessionId": session]))
                case .cancel:
                    try await hub.notify("session/cancel", .object(["sessionId": session]))
                case .respondPermission(let permissionID, let optionID):
                    try await hub.respond(sessionID: sessionID, permissionID: permissionID, optionID: optionID)
                case .answerQuestion(let questionID, let answer):
                    guard let question = questions[questionID] else {
                        self.emit(.clientError("This question is no longer open on \(self.summary.macName)."))
                        return
                    }
                    try await hub.answer(question, with: answer)
                case .setModel(let id):
                    _ = try await hub.request("session/set_model", .object(["sessionId": session, "modelId": .string(id)]))
                    // The menu's check follows the pick (no record carries the model change).
                    if !self.knownModels.isEmpty { self.emit(.modelsAvailable(self.knownModels, current: id)) }
                case .retryWithModel(let model, let text, let attachments, let promptID):
                    // As the Mac's Retry with another model: the move first; a refusal (acpmux's
                    // own words, e.g. a Claude chat the Mac started) sends nothing.
                    _ = try await hub.request("session/set_model", .object(["sessionId": session, "modelId": .string(model)]))
                    if !self.knownModels.isEmpty { self.emit(.modelsAvailable(self.knownModels, current: model)) }
                    self.send(.prompt(text: text, attachments: attachments, steer: false, promptID: promptID, resend: false))
                case .setMode(let id):
                    _ = try await hub.request("session/set_mode", .object(["sessionId": session, "modeId": .string(id)]))
                case .setConfigOption(let id, let value):
                    _ = try await hub.request("session/set_config_option", .object(["sessionId": session, "configId": .string(id), "value": .string(value)]))
                case .removeQueued(let promptID):
                    _ = try await hub.request("_acpmux/queue_remove", .object(["sessionId": session, "promptId": .string(promptID)]))
                case .editQueued(let promptID, let text):
                    _ = try await hub.request("_acpmux/queue_edit", .object([
                        "sessionId": session, "promptId": .string(promptID), "op": .string("update"), "text": .string(text),
                    ]))
                case .sendQueuedNow(let promptID):
                    _ = try await hub.request("_acpmux/queue_edit", .object([
                        "sessionId": session, "promptId": .string(promptID), "op": .string("send_now"),
                    ]))
                case .moveQueued(let promptID, let index):
                    _ = try await hub.request("_acpmux/queue_edit", .object([
                        "sessionId": session, "promptId": .string(promptID), "op": .string("move"), "index": .number(Double(index)),
                    ]))
                case .resumeQueue:
                    // `resume` names no prompt: it lets the whole held queue go (hub/queue_edit.rs).
                    _ = try await hub.request("_acpmux/queue_edit", .object(["sessionId": session, "op": .string("resume")]))
                }
            } catch {
                if AcpmuxSessionSource.isFullAccessRefusal(error) { hub.fullAccessRefused() }
                self.emit(.clientError(AcpmuxSessionSource.message(error)))
            }
        }
    }

    /// acpmux's refusal of what the Mac's mobile host sent marked `requireFullAccess` for this
    /// phone (`server/remote_guard.rs`): its Full-access setting does not cover it.
    nonisolated static func isFullAccessRefusal(_ error: any Error) -> Bool {
        (error as? AcpmuxConnection.RPCError)?.reason == "remote.full_access_required"
    }

    /// This phone's Full-access setting, for the chat's mode menus.
    func fullAccessChanged(_ on: Bool) { emit(.fullAccess(on)) }

    /// ACP prompt content: the text, then per attachment
    /// - an image: an `image` block (base64 data and its MIME type);
    /// - a file: uploaded to the Mac over the link's `upload` service into the
    ///   session's folder (`.cmux/attachments`, next to acpmux's own), then a
    ///   `resource` block with its text when it is UTF-8 text up to 256 KiB, or
    ///   a `resource_link` to the uploaded path (the agent reads it there).
    /// A failed upload throws, so nothing is sent without its attachments.
    func promptBlocks(text: String, attachments: [AgentAttachment], hub: AcpmuxHub) async throws -> [JSONValue] {
        var uploaded: [String: String] = [:]
        // A PDF small enough goes whole as a `document` block (the Mac's), read here, not uploaded;
        // past the prompt's inline budget the rest go as links to their uploaded copies.
        let attachments = await Self.inlinePDFs(attachments)
        let inline = Self.inlineDocuments(attachments)
        for attachment in attachments where attachment.imageMIMEType == nil && !inline.contains(attachment.id) {
            let payload: LinkUpload.Payload
            if let data = attachment.data {
                payload = .data(data)
            } else if let url = attachment.fileURL {
                payload = .file(url)
            } else {
                throw AgentFeatureUnavailable("\(attachment.name) has no contents to send. Attach it again.")
            }
            guard let link = hub.macLink else { throw LinkError(code: "offline", message: "Connect to \(summary.macName) to send \(attachment.name).") }
            uploaded[attachment.id] = try await Self.upload(payload, name: attachment.name, cwd: baseDirectory, link: link, macName: summary.macName)
        }
        // Base64 of PDFs and video frames (megabytes) is made off the main actor.
        return await Task.detached(priority: .userInitiated) {
            Self.promptBlocks(text: text, attachments: attachments, uploaded: uploaded, inlineDocuments: inline)
        }.value
    }

    /// The most PDF bytes one prompt carries inline: their base64 stays well under acpmux's
    /// one-message bound (31 MiB) with room for the text and images.
    nonisolated static let inlineDocumentBudget = 16 << 20

    /// The PDFs that go as `document` blocks: each one up to its cap, in order, while the
    /// prompt's total stays within `inlineDocumentBudget`.
    nonisolated static func inlineDocuments(_ attachments: [AgentAttachment]) -> Set<String> {
        var total = 0
        var ids: Set<String> = []
        for attachment in attachments {
            guard let data = documentData(attachment), total + data.count <= inlineDocumentBudget else { continue }
            total += data.count
            ids.insert(attachment.id)
        }
        return ids
    }

    /// Uploads into the session's folder; a folder the Mac won't write to
    /// (not one of its tabs' folders) falls back to its uploads folder.
    static func upload(_ payload: LinkUpload.Payload, name: String, cwd: String?, link: any MacLink, macName: String) async throws -> String {
        do {
            return try await LinkUpload.upload(payload, name: name, cwd: LinkUpload.folder(cwd), over: link)
        } catch let failure as LinkUpload.Failure where failure.code == "forbidden" || failure.code == "not_found" {
            return try await LinkUpload.upload(payload, name: name, cwd: nil, over: link)
        } catch let failure as LinkUpload.Failure {
            throw AgentFeatureUnavailable("Couldn't send \(name) to \(macName): \(failure.message)")
        }
    }

    /// Each PDF up to `AgentAttachment.maxDocumentBytes` that the composer kept by its URL, with
    /// its bytes read (off the main actor, inside its security scope); the rest as they were.
    nonisolated static func inlinePDFs(_ attachments: [AgentAttachment]) async -> [AgentAttachment] {
        guard attachments.contains(where: { $0.isPDF && $0.data == nil && $0.fileURL != nil }) else { return attachments }
        return await Task.detached(priority: .userInitiated) {
            attachments.map { attachment in
                guard attachment.isPDF, attachment.data == nil, let url = attachment.fileURL,
                      (attachment.byteCount ?? .max) <= AgentAttachment.maxDocumentBytes,
                      let data = ScopedFile(url).withAccess({ try? Data(contentsOf: $0, options: .mappedIfSafe) }),
                      data.count <= AgentAttachment.maxDocumentBytes else { return attachment }
                var read = attachment
                read.data = data
                return read
            }
        }.value
    }

    /// A PDF's bytes when it goes as a `document` block: its own, up to the cap.
    nonisolated static func documentData(_ attachment: AgentAttachment) -> Data? {
        guard attachment.isPDF, let data = attachment.data, data.count <= AgentAttachment.maxDocumentBytes,
              data.starts(with: Array("%PDF".utf8)) else { return nil }
        return data
    }

    /// The blocks for `text` and `attachments`, with each file's path on the Mac. A video's
    /// link is followed by its frames note and each frame (label, then image), as the Mac sends it.
    nonisolated static func promptBlocks(text: String, attachments: [AgentAttachment], uploaded: [String: String] = [:],
                                         inlineDocuments: Set<String>? = nil) -> [JSONValue] {
        let inline = inlineDocuments ?? Self.inlineDocuments(attachments)
        var blocks: [JSONValue] = []
        if !text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
        for attachment in attachments {
            if let mime = attachment.imageMIMEType, let data = attachment.data {
                blocks.append(.object(["type": .string("image"), "mimeType": .string(mime), "data": .string(data.base64EncodedString())]))
            } else if inline.contains(attachment.id), let data = documentData(attachment) {
                blocks.append(.object(["type": .string("document"), "mimeType": .string("application/pdf"),
                                       "data": .string(data.base64EncodedString()), "name": .string(attachment.name)]))
            } else if let path = uploaded[attachment.id] {
                let uri = URL(fileURLWithPath: path).absoluteString
                let mime = Self.mimeType(name: attachment.name)
                if let data = attachment.data, data.count <= 256 << 10, let contents = String(data: data, encoding: .utf8),
                   !contents.contains("\u{0}") {
                    blocks.append(.object(["type": .string("resource"), "resource": .object([
                        "uri": .string(uri), "mimeType": .string(mime), "text": .string(contents),
                    ])]))
                } else {
                    var link: [String: JSONValue] = ["type": .string("resource_link"), "uri": .string(uri),
                                                     "name": .string(attachment.name), "mimeType": .string(mime)]
                    if let size = attachment.data?.count ?? attachment.byteCount { link["size"] = .number(Double(size)) }
                    blocks.append(.object(link))
                    if let video = attachment.video, !video.frames.isEmpty {
                        blocks.append(.object(["type": .string("text"), "text": .string(video.framesNote(name: attachment.name))]))
                        for frame in video.frames {
                            let name = AgentVideo.frameName(attachment.name, atMs: frame.atMs)
                            blocks.append(.object(["type": .string("text"), "text": .string(name)]))
                            blocks.append(.object(["type": .string("image"), "mimeType": .string("image/jpeg"),
                                                   "data": .string(frame.jpeg.base64EncodedString()), "name": .string(name)]))
                        }
                    }
                }
            }
        }
        if blocks.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string("")])) }
        return blocks
    }

    nonisolated static func mimeType(name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: Parity

    public func checkpoints() async throws -> [AgentCheckpoint] {
        throw AgentFeatureUnavailable("Checkpoints are kept by cmux on \(summary.macName). Open Changes on the Mac to restore one.")
    }

    public func restore(_ checkpoint: AgentCheckpoint) async throws -> String {
        throw AgentFeatureUnavailable("Restore checkpoints from the cmux app on \(summary.macName).")
    }

    /// `/status`: acpmux's detail of the session (`_acpmux/info`, which this phone already
    /// reads for approvals), as the Mac's Session status card labels it.
    public func sessionStatus() async throws -> AgentSessionStatus {
        guard let hub else { throw AgentFeatureUnavailable("Status is unavailable for this chat.") }
        do {
            let info = try await hub.request("_acpmux/info", .object(["sessionId": .string(sessionID)]))
            return Self.sessionStatus(info, macName: summary.macName, fallbackHarness: summary.agentName)
        } catch let error as AcpmuxConnection.RPCError {
            throw AgentFeatureUnavailable(error.message)
        }
    }

    /// The card's fields from an `_acpmux/info` reply (webviews acpmux/HarnessStatusCard.tsx): only
    /// labels and the agent's own auth-source label are read, never another value of `agentInfo`
    /// (arbitrary keys there may hold a credential).
    nonisolated static func sessionStatus(_ info: JSONValue, macName: String, fallbackHarness: String) -> AgentSessionStatus {
        let agent = info["agentInfo"] ?? .null
        func text(_ value: JSONValue?) -> String? {
            guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let notReported = String(localized: "Not reported")
        let version = text(agent["version"]) ?? notReported
        let model = text(info["model"]) ?? text(info["models"]?["currentModelId"]) ?? notReported
        let effortOption = info["configOptions"]?.arrayValue?.first { option in
            ["effort", "reasoning_effort", "thought_level"].contains(option["id"]?.stringValue ?? "")
        }
        let effort = text(info["effort"]) ?? text(effortOption?["currentValue"]) ?? notReported
        let auth = text(agent["authSource"]) ?? text(info["authSource"]) ?? notReported
        var routing = text(agent["routeName"]) ?? text(agent["route"]) ?? text(info["route"])
        if routing == nil, let base = text(agent["baseUrl"]) ?? text(agent["baseURL"]) ?? text(info["baseUrl"]) {
            if let url = URL(string: base), let scheme = url.scheme, let host = url.host {
                routing = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
            } else {
                routing = String(localized: "Reported endpoint")
            }
        }
        let settings = (agent["settingsSources"] ?? info["settingsSources"])?.arrayValue?.compactMap { text($0) } ?? []
        var context = notReported
        if let used = info["usage"]?["used"]?.numberValue, let size = info["usage"]?["size"]?.numberValue, size > 0, used >= 0 {
            let percent = Int((min(1, max(0, used / size)) * 100).rounded())
            context = String(localized: "\(percent)% (\(Int(used).formatted()) / \(Int(size).formatted()) tokens)")
        }
        let limits = ((agent["usageLimits"] ?? info["usageLimits"])?["windows"]?.arrayValue ?? []).compactMap { window -> String? in
            guard let id = text(window["id"]), let used = window["usedPercent"]?.numberValue else { return nil }
            let name = switch id {
            case "session": String(localized: "Session")
            case "weekly": String(localized: "Weekly")
            case "weekly_opus": String(localized: "Weekly (Opus)")
            case "weekly_sonnet": String(localized: "Weekly (Sonnet)")
            default: id
            }
            return "\(name) \(Int(min(100, max(0, used)).rounded()))%"
        }
        let fields: [AgentSessionStatus.Field] = [
            .init(label: String(localized: "Version"), value: version),
            .init(label: String(localized: "Session"), value: text(info["sessionId"]) ?? notReported),
            .init(label: String(localized: "CWD"), value: text(info["cwd"]) ?? notReported),
            .init(label: String(localized: "Host"), value: text(info["host"]) ?? text(info["peer"]) ?? macName),
            .init(label: String(localized: "Model"), value: model),
            .init(label: String(localized: "Effort"), value: effort),
            .init(label: String(localized: "Auth source"), value: auth),
            .init(label: String(localized: "Routing"), value: routing ?? notReported),
            .init(label: String(localized: "Settings"), value: settings.isEmpty ? notReported : settings.joined(separator: ", ")),
            .init(label: String(localized: "Context"), value: context),
            .init(label: String(localized: "Usage limits"), value: limits.isEmpty ? notReported : limits.joined(separator: ", ")),
        ]
        return AgentSessionStatus(harness: text(info["harness"]) ?? fallbackHarness, fields: fields)
    }

    public func handoffTargets() async throws -> [AgentHandoffTarget] {
        guard let hub else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        // A workspace tab's folder is the Mac's as the sidebar spells it (`~/code/app`); acpmux
        // takes only an absolute one, and lists every harness without it.
        let params: JSONValue = summary.cwd.hasPrefix("/") ? .object(["cwd": .string(summary.cwd)]) : .object([:])
        do {
            let reply = try await hub.request("_acpmux/harnesses", params)
            return Self.handoffTargets(reply, excluding: summary.harness)
        } catch let error as AcpmuxConnection.RPCError {
            throw AgentFeatureUnavailable(error.message)
        }
    }

    /// `_acpmux/harnesses` → targets: every harness but the session's own; unavailable ones keep their reason.
    static func handoffTargets(_ reply: JSONValue, excluding harness: String) -> [AgentHandoffTarget] {
        guard case .object(let harnesses)? = reply["harnesses"] else { return [] }
        return harnesses.keys.sorted().compactMap { id in
            guard id != harness, let entry = harnesses[id] else { return nil }
            let name = entry["displayName"]?.stringValue ?? entry["title"]?.stringValue ?? entry["name"]?.stringValue ?? id
            let reason = entry["unavailable"]?.stringValue ?? entry["unavailable"]?["reason"]?.stringValue ?? entry["probeError"]?.stringValue
            return AgentHandoffTarget(id: id, name: name, family: entry["family"]?.stringValue, unavailableReason: reason)
        }
    }

    public func prepareHandoff(to target: AgentHandoffTarget) async throws -> AgentHandoffDraft {
        guard let hub else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        do {
            let reply = try await hub.request("_acpmux/handoff_prepare", .object([
                "sessionId": .string(sessionID), "harness": .string(target.id),
                "handoffKey": .string("ios-\(sessionID)-\(target.id)"),
            ]))
            guard let draft = Self.handoffDraft(reply, target: target) else {
                throw AgentFeatureUnavailable("\(summary.macName) sent a continuation this app can't read.")
            }
            return draft
        } catch let error as AcpmuxConnection.RPCError {
            throw AgentFeatureUnavailable(Self.handoffMessage(error))
        }
    }

    static func handoffDraft(_ value: JSONValue, target: AgentHandoffTarget) -> AgentHandoffDraft? {
        guard let id = value["handoffId"]?.stringValue, let capsule = value["capsule"] else { return nil }
        let coverage = (value["target"]?["coverage"]?.arrayValue ?? value["source"]?["coverage"]?.arrayValue ?? []).compactMap { item -> AgentHandoffDraft.Coverage? in
            guard let name = item["item"]?.stringValue, let status = item["status"]?.stringValue.flatMap(AgentHandoffDraft.Coverage.Status.init(rawValue:)) else { return nil }
            return .init(item: name, status: status, detail: item["detail"]?.stringValue)
        }
        return AgentHandoffDraft(
            id: id, revision: Int(value["revision"]?.numberValue ?? 0), target: target,
            capsule: capsule["text"]?.stringValue ?? "", maxBytes: Int(capsule["maxBytes"]?.numberValue ?? 65536),
            coverage: coverage, checkpointReference: capsule["checkpoint"]?["ref"]?.stringValue, promptID: value["promptId"]?.stringValue
        )
    }

    static func handoffMessage(_ error: AcpmuxConnection.RPCError) -> String {
        switch error.reason {
        case "source_busy": "Wait for the agent to finish (no turn running, nothing queued or waiting) before continuing elsewhere."
        case "checkpoint_required": "Save a repository checkpoint first."
        case "permission.person_required": "Confirm this on your Mac to continue."
        default: error.message
        }
    }

    public func startHandoff(_ draft: AgentHandoffDraft) async throws -> AgentHandoffReceipt {
        guard let hub else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        do {
            let reply = try await hub.request("_acpmux/handoff_start", .object([
                "handoffId": .string(draft.id), "revision": .number(Double(draft.revision)),
                "promptId": .string(draft.promptID ?? draft.id),
                "capsule": .object(["text": .string(draft.capsule), "memoryRefs": .array([])]),
                "checkpoint": .object(["ref": .string(draft.checkpointReference ?? ""), "attest": .bool(true)]),
            ]))
            return AgentHandoffReceipt(targetSessionID: reply["targetSessionId"]?.stringValue ?? "", targetName: draft.target.name)
        } catch let error as AcpmuxConnection.RPCError {
            throw AgentFeatureUnavailable(Self.handoffMessage(error))
        }
    }

    public func discardHandoff(_ draft: AgentHandoffDraft) async {
        _ = try? await hub?.request("_acpmux/handoff_discard", .object(["handoffId": .string(draft.id)]))
    }

    /// Relative references resolve against the session's folder as acpmux
    /// reports it (absolute); the summary's is the workspace's, abbreviated
    /// with `~` for display, which can't be resolved on the phone.
    var baseDirectory: String {
        if let cwd = hub?.sessions[sessionID]?.cwd, cwd.hasPrefix("/") { return cwd }
        return summary.cwd
    }

    /// A recorded prompt image's bytes from acpmux (`_acpmux/attachment`: only an image this
    /// session's own log names is read).
    public func attachmentData(_ attachment: AgentAttachment) async -> Data? {
        guard let id = attachment.recordedImageID else { return nil }
        if let cached = imageCache[id] { return cached }
        // One read per image: a thumbnail and its preview asking at once share it.
        if let reading = imageReads[id] { return await reading.value }
        let hub = hub, session = sessionID
        let reading = Task { @MainActor () -> Data? in
            guard let hub,
                  let reply = try? await hub.request("_acpmux/attachment", .object(["sessionId": .string(session), "id": .string(id)])),
                  let base64 = reply["data"]?.stringValue else { return nil }
            return Data(base64Encoded: base64)
        }
        imageReads[id] = reading
        let data = await reading.value
        imageReads[id] = nil
        // A refusal or a dropped link is not cached: the next look tries again.
        if let data {
            imageCache[id] = data
            imageCacheOrder.append(id)
            while imageCacheOrder.count > Self.imageCacheLimit { imageCache[imageCacheOrder.removeFirst()] = nil }
        }
        return data
    }

    /// Recorded prompt images read this launch, by acpmux id (the newest few: bubbles scroll back).
    private var imageCache: [String: Data] = [:]
    private var imageCacheOrder: [String] = []
    private var imageReads: [String: Task<Data?, Never>] = [:]
    static let imageCacheLimit = 24

    public var artifactSource: any ArtifactSource {
        let hub = hub
        let directory = baseDirectory
        let scope = ArtifactThumbnailOwner.remote(
            accountID: summary.accountID, macID: summary.macID,
            resource: "agent:\(sessionID):\(directory)")
        return LinkFileArtifactSource(macName: summary.macName, baseDirectory: directory,
                                      thumbnailCacheScope: scope) {
            await MainActor.run { hub?.macLink }
        }
    }

    /// Display copy for a refused call.
    static func message(_ error: any Error) -> String {
        if error is AcpmuxHub.ApprovalCancelled { return "Not approved: Face ID was cancelled." }
        if error is AcpmuxHub.ApproverUnsupported {
            return "Not approved: update cmux on the Mac to approve from this iPhone, or approve on the Mac."
        }
        if let failure = error as? PhoneKeys.Failure { return "Not approved: \(failure.message)" }
        if let error = error as? AcpmuxConnection.RPCError {
            switch error.reason {
            case "permission.person_required":
                return "Allow this iPhone in the Mac's Settings → Mobile, or approve on the Mac."
            case "trust.pending", "trust.untrusted": return "Trust this folder on your Mac first."
            case "remote.lasting_grant_refused": return "From an iPhone you can allow once or deny. Allow for this chat on the Mac."
            case "remote.full_access_required": return "Full access is off for this iPhone. Turn it on in Settings > Devices on the Mac."
            default:
                if error.message.hasPrefix("no pending permission") { return "Already answered on your Mac." }
                // An agent's raw JSON error (a model the account lacks) reads as a sentence.
                return TurnFailureCopy.plain(error.message)
            }
        }
        return LinkController.reason(error)
    }

    func linkDown() {
        // An attach still waiting on the old connection ends without touching this chat.
        generation += 1
        attachTask?.cancel()
        attachTask = nil
        retryTask?.cancel()
        retryTask = nil
        failures = 0
        attached = false
        attaching = false
        refillPending = false
        held = []
        emit(.status(.disconnected))
        // Only a connection's own `initialize` says Full access covers it (`attach` sends it again).
        fullAccessChanged(false)
    }

    /// The Mac dropped notifications to this connection (`_acpmux/lagged`): attach again
    /// from the last record applied, holding live records until that page is in, so the
    /// records in the gap are applied in order instead of skipped as older than `lastSeq`.
    func refill() {
        // An attach in flight may have read its page before the Mac dropped records: it reads
        // on before applying what it held (`attach`).
        guard !attaching else {
            refillPending = true
            return
        }
        attached = false
        linkUp()
    }

    /// A lag that came while an attach ran (`refill`).
    private var refillPending = false

    /// Counts attaches and link drops: an attach whose number is no longer current (the link
    /// dropped, or a newer attach started) applies nothing.
    private var generation = 0
    /// Attaches failed in a row since the last one that caught up.
    private var failures = 0
    /// The next attach after a failed one (`scheduleRetry`).
    private var retryTask: Task<Void, Never>?
    /// The attach running (`linkUp`), cancelled when the link drops.
    private var attachTask: Task<Void, Never>?
    /// The longest one catch-up request may take: a link that stops answering without
    /// closing fails the page, and the attach tries again (`scheduleRetry`).
    static let pageTimeout: Duration = .seconds(30)

    func linkUp() {
        guard !attaching, let hub, hub.isReady else { return }
        retryTask?.cancel()
        retryTask = nil
        attaching = true
        generation += 1
        let generation = generation
        // The task holds the source only between its requests, never across one: a chat
        // nobody keeps goes away while a page is read, and its deinit cancels the read.
        attachTask = Task { [weak self] in
            while let read = self?.nextRead(generation) {
                let pages = await Self.readPages(hub, read) { [weak self] in self?.generation == generation }
                guard self?.caughtUp(pages, read, generation) == true else { return }
            }
        }
    }

    isolated deinit {
        attachTask?.cancel()
        retryTask?.cancel()
    }

    /// How long a failed attach waits before the next try: 250 ms, doubling, at most 15 s.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        .milliseconds(min(15_000, 250 << min(max(failures - 1, 0), 6)))
    }

    /// A failed attach (a page refused or timed out on a link that stays up) tries again, from
    /// the last record applied. Stops when an attach catches up, the link drops (`linkDown`),
    /// another attach starts (`linkUp`) or the source goes away.
    private func scheduleRetry() {
        failures += 1
        let delay = Self.retryDelay(afterFailures: failures)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.linkUp()
        }
    }

    /// One catch-up's start: from the last record applied (none: a first attach).
    struct CatchUpRead {
        let sessionID: String
        let after: Int
        var firstAttach: Bool { after == 0 }
    }

    /// What a catch-up read: the attach reply, its records in seq order, whether older ones
    /// exist (a first attach), and the error that stopped it, if one did.
    struct CatchUpPages {
        var result: JSONValue = .null
        var page: [JSONValue] = []
        var earlier = false
        var failure: (any Error)?
    }

    /// The next catch-up of attach `generation`, or nil when it is no longer current.
    private func nextRead(_ generation: Int) -> CatchUpRead? {
        guard generation == self.generation else { return nil }
        refillPending = false
        return CatchUpRead(sessionID: sessionID, after: lastSeq)
    }

    /// A prompt record: where a turn starts.
    /// A message steered into a running turn (`msg.steer`) is a `user_message` too, and starts none.
    static func isPrompt(_ record: JSONValue) -> Bool {
        record["kind"]?.stringValue == "user_message" && record["msg"]?["steer"] != .bool(true)
    }

    /// Reads from `read.after` to the log's end (a first attach: the newest page only, from its
    /// first prompt; older pages come with ``loadEarlierHistory()``). Each request is bounded, and none is sent once the
    /// attach is no longer `current` (the link dropped, another attach started, the chat went
    /// away): the hub's next connection is not its own.
    private static func readPages(_ hub: AcpmuxHub, _ read: CatchUpRead, current: @escaping () -> Bool) async -> CatchUpPages {
        var out = CatchUpPages()
        func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
            guard current(), !Task.isCancelled else { throw CancellationError() }
            return try await hub.request(method, .object(params), timeout: pageTimeout)
        }
        do {
            var params: [String: JSONValue] = [
                "sessionId": .string(read.sessionID),
                "limit": .number(Double(pageSize)),
                "kinds": chatKinds,
                "eventStream": .bool(true),
            ]
            if read.firstAttach {
                params["maxBytes"] = .number(Double(openBytes))
            } else {
                params["afterSeq"] = .number(Double(read.after))
            }
            out.result = try await request("_acpmux/attach", params)
            out.page = out.result["events"]?.arrayValue ?? []
            // A reattach (the link came back, or the Mac said this connection lagged) asks for
            // what came after the last record applied, oldest first and one page at a time: page
            // forward until a page reaches the log's end. Otherwise the next live record moves
            // `lastSeq` past the rest of the gap, and the chat never sees what was in it (a
            // turn's end, a decision made on the Mac).
            if !read.firstAttach {
                var more = out.result["hasMore"] == .bool(true)
                while more, let newest = out.page.last?["seq"]?.numberValue {
                    let next = try await request("_acpmux/events", [
                        "sessionId": .string(read.sessionID), "afterSeq": .number(newest),
                        "limit": .number(Double(pageSize)), "kinds": chatKinds,
                    ])
                    let events = next["events"]?.arrayValue ?? []
                    out.page += events
                    more = !events.isEmpty && next["hasMore"] == .bool(true)
                }
            }
            // First attach: the newest page only; older pages come as the reader scrolls up.
            out.earlier = read.firstAttach && out.result["hasMore"] == .bool(true)
            if out.earlier {
                if let first = out.page.firstIndex(where: isPrompt) {
                    // What is before the first prompt belongs to an older turn: it comes with
                    // that turn's page, never twice.
                    out.page.removeFirst(first)
                } else if let oldest = out.page.first?["seq"]?.numberValue {
                    // The page is inside one turn longer than itself (a long run): its prompt
                    // alone is read, so the page has a turn to go in. Without it the chat
                    // opened empty.
                    // A few, since messages steered into the turn are `user_message`s too.
                    let opener = try await request("_acpmux/events", [
                        "sessionId": .string(read.sessionID), "beforeSeq": .number(oldest),
                        "limit": .number(16), "kinds": .array([.string("user_message")]),
                    ])
                    let records = opener["events"]?.arrayValue ?? []
                    let start = records.lastIndex(where: isPrompt)
                    out.page = start.map { [records[$0]] + out.page } ?? out.page
                    out.earlier = start.map { $0 > 0 || opener["hasMore"] == .bool(true) } ?? false
                }
            }
        } catch {
            out.failure = error
        }
        return out
    }

    /// Applies a catch-up's pages. False when it caught up or ended (failed: a retry is
    /// scheduled; stale: nothing is applied); true when it must read again first: the Mac
    /// dropped records while it read (`refill`), and the held records may come after one it
    /// dropped. Applying them would move `lastSeq` past the dropped one for good.
    private func caughtUp(_ pages: CatchUpPages, _ read: CatchUpRead, _ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        guard apply(pages, read) else {
            attaching = false
            attachTask = nil
            // Live records held meanwhile are newer than the gap: applying them would move
            // `lastSeq` past it for good. The retry reads to the log's end, them included.
            held = []
            scheduleRetry()
            return false
        }
        if refillPending { return true }
        attaching = false
        attachTask = nil
        failures = 0
        attached = true
        let pending = held
        held = []
        for record in pending { apply(record: record) }
        return false
    }

    /// Applies what a catch-up read as one batch. False when a request failed: a reattach
    /// applies what it read up to its last record (no gap: pages are read oldest first from
    /// `lastSeq`), and the rest waits for the retry.
    private func apply(_ pages: CatchUpPages, _ read: CatchUpRead) -> Bool {
        let (result, page) = (pages.result, pages.page)
        log.info("attach \(self.sessionID, privacy: .public) after \(read.after, privacy: .public): \(page.count, privacy: .public) records, through \(page.last?["seq"]?.numberValue ?? 0, privacy: .public), held \(self.held.count, privacy: .public), failed \(pages.failure != nil, privacy: .public)")
        if let failure = pages.failure {
            // Said once per run of failures, not on every retry.
            if failures == 0 { emit(.clientError(Self.message(failure))) }
            // A first attach's page is the newest records, with a gap before them until the
            // older pages are in: nothing of it is applied. A reattach's is the oldest after
            // `lastSeq`: what was read has no gap and is applied.
            guard !read.firstAttach, !page.isEmpty else { return false }
            beginHistory()
            for record in page { apply(record: record) }
            endHistory()
            return false
        }
        if let detail = result["session"], let session = AcpmuxSession(detail) {
            summary.status = session.summaryStatus
            if !session.name.isEmpty { summary.name = session.name }
        }
        // The replay boundary is the attach reply: its page (and the session state it
        // carries) is history, applied as one change, so the chat opens on the whole
        // transcript instead of animating every past record in (or, on a reattach, the
        // records missed while the link was down). Records after the reply are live.
        beginHistory()
        if read.firstAttach {
            emit(.earlierHistory(pages.earlier))
            // Older pages are read before the oldest prompt shown.
            earlierBefore = pages.earlier ? page.first(where: Self.isPrompt)?["seq"]?.numberValue.map { Int($0) } : nil
            earlierCarry = []
        }
        // The reply's session state is as of its `lastSeq` (read with it, before its page),
        // and a catch-up may read records written after it: a turn that ended in a later page
        // must not show as running again. The state goes in at that seq, among the records.
        let boundary = Self.stateSeq(result)
        var stateApplied = false
        for record in page {
            if !stateApplied, Int(record["seq"]?.numberValue ?? 0) > boundary {
                applyState(result, page: page)
                stateApplied = true
            }
            apply(record: record)
        }
        if !stateApplied { applyState(result, page: page) }
        endHistory()
        return true
    }

    /// The seq an attach reply's session state is as of: its `lastSeq` (an acpmux that does
    /// not send it: after the whole catch-up, as before).
    static func stateSeq(_ result: JSONValue) -> Int {
        if let seq = result["lastSeq"]?.numberValue { return Int(seq) }
        return .max
    }

    /// An attach reply's session state, in the catch-up at its own seq (`stateSeq`): what
    /// the catch-up applies after it is the records in `page` and `held` newer than `lastSeq`.
    private func applyState(_ result: JSONValue, page: [JSONValue]) {
        // This connection's Full-access setting, before the modes it widens.
        emit(.fullAccess(hub?.fullAccess ?? false))
        // The session's models, modes and options as acpmux kept them then (D4: a running
        // chat had no model menu, as they only came with later updates). After the records
        // before it: a pick (set_model, set_mode, set_config_option) writes no record, so an
        // older update must not win over the state.
        if let detail = result["session"] {
            for event in Self.sessionState(detail) {
                if case .modelsAvailable(let models, _) = event { knownModels = models }
                emit(event)
            }
        }
        // Permissions still open (records may be older than the page). Before the records
        // after the state, so a decision among them lands after its request; an ask whose own
        // request comes after the state (later in the catch-up, or held) comes with it
        // instead, in order (on the turn it belongs to). An ask whose record comes later
        // still (it raced the reply) is sent again with that record, and the chat moves it to
        // its turn (`AgentChatStore`).
        let laterAsks = Set((page + held).compactMap { record -> String? in
            let seq = Int(record["seq"]?.numberValue ?? 0)
            guard seq == 0 || seq > lastSeq, record["kind"]?.stringValue == "permission_request" else { return nil }
            return record["msg"]?["permissionId"]?.stringValue
        })
        for entry in result["session"]?["pending"]?.arrayValue ?? [] {
            if let id = entry["permissionId"]?.stringValue, !laterAsks.contains(id), let request = entry["request"],
               let event = records.permission(id, request: request) { emitPermission(event, listedOnly: true) }
        }
        emit(.status(summary.status))
    }

    /// The session's models (from attach), for the menu after a pick.
    private var knownModels: [ACPModelInfo] = []

    /// `_acpmux/attach`'s session detail as chat events: `models` ({currentModelId,
    /// availableModels}), else a config option of category `model`; `modes` ({currentModeId,
    /// availableModes}); `configOptions` (effort and the rest).
    static func sessionState(_ detail: JSONValue) -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = []
        let options: [ACPConfigOption] = detail["configOptions"].flatMap { value in
            guard case .array = value, let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode([ACPConfigOption].self, from: data)
        } ?? []
        var models = (detail["models"]?["availableModels"]?.arrayValue ?? []).compactMap { model -> ACPModelInfo? in
            guard let id = model["modelId"]?.stringValue, !id.isEmpty else { return nil }
            return ACPModelInfo(id: id, name: model["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
        var current = detail["models"]?["currentModelId"]?.stringValue
        if models.isEmpty, let option = options.first(where: { $0.category == "model" || $0.id == "model" }) {
            models = option.options.map { ACPModelInfo(id: $0.value, name: $0.name.flatMap { $0.isEmpty ? nil : $0 } ?? $0.value) }
            current = option.currentValue
        }
        if !models.isEmpty { events.append(.modelsAvailable(models, current: current)) }
        let modes = (detail["modes"]?["availableModes"]?.arrayValue ?? []).compactMap { mode -> ACPMode? in
            guard let id = mode["id"]?.stringValue, !id.isEmpty else { return nil }
            return ACPMode(id: id, name: mode["name"]?.stringValue ?? id, description: mode["description"]?.stringValue)
        }
        if !modes.isEmpty { events.append(.modesAvailable(modes, current: detail["modes"]?["currentModeId"]?.stringValue)) }
        if !options.isEmpty { events.append(.update(.configOptions(options))) }
        // Whether a failed turn holds the queue now (its `queue_paused` record may be older
        // than the history the chat opened on).
        if case .bool(let paused)? = detail["queuePaused"] { events.append(.queuePaused(paused, reason: nil)) }
        return events
    }

    // MARK: Older history (scrolling up)

    /// Older records are read before this seq, the oldest prompt shown; nil when the chat
    /// shows its start (or has not opened).
    private var earlierBefore: Int?
    /// Records read before `earlierBefore` with no prompt among them yet (a turn longer than
    /// the reads): they go in with the page that reaches their prompt.
    private var earlierCarry: [JSONValue] = []
    private var loadingEarlier = false

    public func loadEarlierHistory() {
        guard !loadingEarlier else { return }
        guard let before = earlierBefore, let hub, hub.isReady else {
            // Nothing to read now (the start is shown, or the link is down): the chat's
            // loading state ends, so the next scroll up asks again.
            yieldEarlier([], hasEarlier: earlierBefore != nil)
            return
        }
        loadingEarlier = true
        let sessionID = sessionID
        Task { [weak self] in
            let read = await Self.readEarlier(hub, sessionID: sessionID, before: before)
            self?.applyEarlier(read, before: before)
        }
    }

    /// What one scroll up read: records oldest first, whether older ones remain, and whether
    /// a read failed (nothing is applied; the next scroll up tries again).
    struct EarlierRead {
        var records: [JSONValue] = []
        var more = false
        var failed = false
    }

    /// Reads byte-capped pages before `before` until one holds a prompt, the log starts, or
    /// `maxEarlierReads` pages were read.
    private static func readEarlier(_ hub: AcpmuxHub, sessionID: String, before: Int) async -> EarlierRead {
        var out = EarlierRead()
        var cursor = before
        do {
            for _ in 0..<maxEarlierReads {
                let page = try await hub.request("_acpmux/events", .object([
                    "sessionId": .string(sessionID), "beforeSeq": .number(Double(cursor)),
                    "limit": .number(Double(pageSize)), "maxBytes": .number(Double(olderBytes)), "kinds": chatKinds,
                ]), timeout: pageTimeout)
                let events = page["events"]?.arrayValue ?? []
                let hasMore = page["hasMore"] == .bool(true)
                // hasMore means the server promises older records. An empty or
                // non-advancing page is a failed read, never the start of history:
                // dropping earlierBefore here permanently hides older turns.
                if hasMore {
                    guard let oldest = events.first?["seq"]?.numberValue,
                          oldest.isFinite, oldest >= 0, oldest < Double(cursor) else {
                        out.failed = true
                        break
                    }
                }
                out.records = events + out.records
                out.more = !events.isEmpty && hasMore
                guard out.more, let oldest = events.first?["seq"]?.numberValue,
                      !events.contains(where: isPrompt) else { break }
                cursor = Int(oldest)
            }
        } catch {
            out.failed = true
        }
        return out
    }

    /// Puts what a scroll up read in front of the chat as whole turns: from the oldest prompt
    /// read (what is before it belongs to an older prompt, and is read with the next page).
    private func applyEarlier(_ read: EarlierRead, before: Int) {
        loadingEarlier = false
        guard earlierBefore == before else { return }
        let all = read.records + earlierCarry
        var page: [JSONValue] = []
        if read.failed {
            // Nothing applied: the next scroll up reads the same page again.
        } else if !read.more {
            page = all
            earlierCarry = []
            earlierBefore = nil
        } else if let first = all.firstIndex(where: Self.isPrompt), let seq = all[first]["seq"]?.numberValue {
            page = Array(all[first...])
            earlierCarry = []
            earlierBefore = Int(seq)
        } else if let oldest = all.first?["seq"]?.numberValue {
            // Still inside one turn longer than the reads: read on at once (the chat stays
            // loading), since nothing on screen changes to ask again.
            earlierCarry = all
            earlierBefore = Int(oldest)
            log.info("earlier \(self.sessionID, privacy: .public) before \(before, privacy: .public): no prompt yet, \(all.count, privacy: .public) records carried")
            loadEarlierHistory()
            return
        }
        let events = page.flatMap { records.map($0) }
        let hasEarlier = earlierBefore != nil
        log.info("earlier \(self.sessionID, privacy: .public) before \(before, privacy: .public): \(page.count, privacy: .public) records, failed \(read.failed, privacy: .public), more \(hasEarlier, privacy: .public)")
        // A new reader of this source gets the older turns first, then the rest, in order.
        if !events.isEmpty { replay.insert(contentsOf: events, at: 0) }
        yieldEarlier(events, hasEarlier: hasEarlier)
    }

    private func yieldEarlier(_ events: [AgentSessionEvent], hasEarlier: Bool) {
        replay.append(.earlierHistory(hasEarlier))
        for continuation in continuations { continuation.yield(.earlierPage(events, hasEarlier: hasEarlier)) }
    }

    func receive(record: JSONValue) {
        guard attached else {
            // Only while an attach runs: its pages may end before them. With no attach
            // running, the next one reads from `lastSeq` to the log's end, these included.
            if attaching { held.append(record) }
            return
        }
        apply(record: record)
    }

    /// A record in order: one already applied (its seq at most `lastSeq`) is skipped.
    private func apply(record: JSONValue) {
        let seq = Int(record["seq"]?.numberValue ?? 0)
        guard seq == 0 || seq > lastSeq else { return }
        if seq > 0 { lastSeq = seq }
        for event in records.map(record) {
            switch event {
            case .permissionRequest, .question:
                emitPermission(event)
            default:
                emit(event)
            }
        }
    }

    private var seenPermissions: Set<String> = []
    /// Asks shown from an attach reply's pending list whose own record has not come yet.
    private var listedPermissions: Set<String> = []

    /// `listedOnly`: from the attach reply's pending list, not a record.
    private func emitPermission(_ event: AgentSessionEvent, listedOnly: Bool = false) {
        let id: String
        switch event {
        case .permissionRequest(let request): id = request.id
        case .question(let question):
            id = question.id
            questions[question.id] = question
        default: return
        }
        if seenPermissions.insert(id).inserted {
            if listedOnly { listedPermissions.insert(id) }
        } else if listedOnly || listedPermissions.remove(id) == nil {
            return
        }
        emit(event)
    }

    /// Events of the attach reply, sent as one `.batch` by `endHistory()` (no
    /// suspension point between the two, so nothing else lands in between).
    private var history: [AgentSessionEvent]?

    private func beginHistory() {
        history = []
    }

    private func endHistory() {
        guard let events = history else { return }
        history = nil
        guard !events.isEmpty else { return }
        replay.append(contentsOf: events)
        for continuation in continuations { continuation.yield(.batch(events)) }
    }

    private func emit(_ event: AgentSessionEvent) {
        switch event {
        case .clientError, .promptNotSent:
            break
        default:
            if history != nil {
                history?.append(event)
                return
            }
            replay.append(event)
        }
        for continuation in continuations { continuation.yield(event) }
    }
}
