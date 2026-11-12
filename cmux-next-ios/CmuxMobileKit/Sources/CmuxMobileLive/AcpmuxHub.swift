import CmuxAgentQuestion
import CmuxConnectivityTelemetry
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
    /// Every chat the watch reported, newest page first (`AcpmuxHub+SessionPages.swift`): ready
    /// with the first page, the rest read after it.
    public internal(set) var sessions: [String: AcpmuxSession] = [:]
    public private(set) var isReady = false
    /// A failure binding the channel (shown in diagnostics).
    public private(set) var lastError: String?
    /// The link the channel rides on (artifact previews open `file` channels on it).
    @ObservationIgnored public var macLink: (any MacLink)?

    @ObservationIgnored var connection: AcpmuxConnection?
    /// Callers of `waitUntilReady` (a Feed answer whose Mac's link is opening).
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [String: WeakSource] = [:]
    /// The read of the list's later pages on the current connection (`AcpmuxHub+SessionPages.swift`).
    @ObservationIgnored var restOfList: Task<Void, Never>?
    /// Chats a `session_changed` told since this connection's watch began: newer than any page row.
    @ObservationIgnored var toldSinceWatch: Set<String> = []
    /// Chats purged since this connection's watch began: a later page must not bring them back.
    @ObservationIgnored var purgedSinceWatch: Set<String> = []
    /// acpmux dropped notices since this connection's watch began (`_acpmux/lagged` with
    /// `dropped`): a chat's notice may be lost, so the rest's end lets no chat go on its account.
    @ObservationIgnored var droppedSinceWatch = false
    /// Every chat of the Mac is in `sessions` (the whole list was read on this connection). A
    /// chat not in `sessions` before then may be one of the older ones still being read.
    public internal(set) var listWhole = false
    /// Where each chat keeps its newest records on this phone (nil: none kept, as in tests and
    /// Cloud chats). Set by the live coordinator before any chat opens.
    @ObservationIgnored public var transcriptCache: AgentTranscriptCache?
    /// Watch-level events for the Feed: `(sessionId, notification)`.
    @ObservationIgnored public var onWatchEvent: (@MainActor (AcpmuxHub.WatchEvent) -> Void)?
    /// Signs an Allow or an answer with the phone's approval key
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
    /// The protocol surfaces the Mac's acpmux serves (`initialize` `_meta.acpmux.capabilities`,
    /// acpmux `capabilities.rs`); empty until this connection initializes.
    @ObservationIgnored private(set) var capabilities: Set<String> = []

    /// The phone's approval signer for the linked Mac.
    public struct Approver: Sendable {
        /// The phone's link device id, as the Mac paired it.
        public var phoneID: String
        /// The Mac's mobile device id.
        public var macDevice: String
        /// Returns the approval signer (`reason` says what is approved). The
        /// payload, and so its expiry, is made only after it returns, so a slow
        /// signer never lets an answer expire on the way.
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

    /// An answer a peer never counts from this phone (acpmux `mac_approvers::may_allow`): anything but a
    /// one-time allow. Thrown before the approval key is asked, so the person is not asked to sign it.
    public struct PeerAllowOnceOnly: Error, Equatable {
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
        restOfList?.cancel()
        restOfList = nil
        toldSinceWatch = []
        purgedSinceWatch = []
        droppedSinceWatch = false
        listWhole = false
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
            ConnectivityTelemetry.shared.record(.hub, "channel_closed", outcome: .failure,
                                                fields: ["last_error": .text(self.lastError ?? "")])
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
            capabilities = Set((initialized["_meta"]?["acpmux"]?["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue))
            // The newest page only (CMUX-563): a Mac with hundreds of chats sent its whole list
            // (megabytes) before the phone was ready. The rest is read after ready, below.
            let first = try await Self.firstPage(connection, timeout: requestTimeout)
            guard !(await connection.isClosed), self.connection === connection else { return }
            let firstIDs = applyFirstPage(first.rows, whole: first.cursor == nil)
            let next = sessions
            isReady = true
            lastError = nil
            let waiters = readyWaiters
            readyWaiters = [:]
            for waiter in waiters.values { waiter.resume(returning: true) }
            log.info("acpmux ready, \(next.count, privacy: .public) sessions")
            ConnectivityTelemetry.shared.record(.hub, "ready", outcome: .success, fields: [
                "sessions": .number(Double(next.count)),
                "full_access": .flag(fullAccess),
                "capabilities": .number(Double(capabilities.count)),
            ], detail: capabilities.sorted().joined(separator: ","))
            for entry in sources.values { entry.source?.linkUp() }
            onWatchEvent?(.sessionsLoaded(Array(next.values)))
            if let cursor = first.cursor {
                restOfList = Task { [weak self] in
                    await self?.readRest(after: cursor, on: connection, firstPage: firstIDs, timeout: requestTimeout)
                }
            }
            // With a cursor, only the page's chats: older rows kept from the last connection carry
            // a stale `lastSeq`; the rest seeds the others once read.
            await seedPending(connection, requestTimeout: requestTimeout, among: first.cursor == nil ? nil : firstIDs)
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
            // A bind cancelled by a newer link is not a failure.
            if !Task.isCancelled, !(error is CancellationError) {
                let code: ConnectivityEvent.Value = (error as? LinkError).map { ConnectivityEvent.Value.safeCode($0.code) } ?? .code("other")
                ConnectivityTelemetry.shared.record(.hub, "bind_failed", outcome: .failure,
                                                    fields: ["error_code": code, "reason": .text(lastError ?? "")],
                                                    detail: String(describing: error))
            }
        }
    }

    /// Asks that were already open before this connection watched: acpmux
    /// notifies `permission_pending` only for new ones, so read each waiting
    /// session's permission records and report those with no decision.
    /// `among`: only those chats (nil: every chat).
    func seedPending(_ connection: AcpmuxConnection, requestTimeout: Duration, among: Set<String>? = nil) async {
        for session in sessions.values where session.pendingPermissions > 0 && among.map({ $0.contains(session.id) }) != false {
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

    /// ``AcpmuxConnection/submit(_:_:)`` on the current connection: returns once the request
    /// is written, with the connection that answers it.
    public func submit(_ method: String, _ params: JSONValue) async throws -> (AcpmuxConnection, Int) {
        guard let connection, isReady else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return (connection, try await connection.submit(method, params))
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

    /// The sudo card's answer (acpmux hub/elevation.rs): `_acpmux/secret_submit` with the
    /// password and this phone's signature over the card's id, `card_provide` and the card's
    /// nonce (acpmux `Hub::card_answer_signed`); a Deny sends no value and needs no signature.
    /// The password goes in the request only, never in a log line or an error.
    public func answerElevation(sessionID: String, ask: AgentElevationAsk, password: AgentSecretText?) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "secretId": .string(ask.id)]
        if let password {
            guard let approver else { throw ApproverUnsupported() }
            let sign = try await approver.authorize("Run \(ask.commandLine) as root")
            let expiresAt = Int(approver.now().timeIntervalSince1970 + ApprovalPayload.lifetime)
            let payload = ApprovalPayload(
                instance: ask.instance, macDevice: approver.macDevice, approver: approver.phoneID,
                session: sessionID, permission: ask.id, option: Self.elevationOption, nonce: ask.nonce,
                expiresAt: expiresAt)
            params["_meta"] = payload.meta(signature: try sign(payload.message))
            params["value"] = .string(password.value)
        }
        _ = try await request("_acpmux/secret_submit", .object(params))
    }

    /// The option a phone signs for a sudo card's Approve (acpmux `secrets::CARD_PROVIDE`).
    static let elevationOption = "card_provide"

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

    /// `_meta` for an Allow or an answer signed with the approval key; nil for a reject option (never signed), an unpaired phone or a
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
        // A prompt of another daemon run than this Mac's is a peer's (a chat opened with `--host`), as the
        // Mac app decides. The peer counts only a one-time allow from this phone, as the Mac's own signer
        // checks first (`signPeerAllow`): anything else is refused here, before the key is asked.
        let peer = personInstance.map { instance != $0 } ?? false
        if peer, !Self.peerMayAllow(pending["request"], optionID: optionID) { throw PeerAllowOnceOnly() }
        let title = pending["request"]?["toolCall"]?["title"]?.stringValue ?? ""
        // What is approved: the chosen answers, or the Mac's own title (review M1, L3).
        let reason = answers != nil ? (answerReason ?? "Send your answer to the agent") : Self.allowReason(title: title)
        let sign = try await approver.authorize(reason)
        // The expiry starts once the signer returned.
        let expiresAt = Int(approver.now().timeIntervalSince1970 + ApprovalPayload.lifetime)
        // The peer checks it as one of this Mac's enrolled phones, against its own run.
        if peer {
            let payload = PeerApprovalPayload(
                instance: instance, approver: PeerApprovalPayload.peerID(macDevice: approver.macDevice, phone: approver.phoneID),
                session: info["sessionId"]?.stringValue ?? sessionID, permission: permissionID,
                toolCall: pending["request"]?["toolCall"]?["toolCallId"]?.stringValue ?? "", option: optionID, nonce: nonce,
                expiresAt: expiresAt, answers: answers)
            return payload.meta(signature: try sign(payload.message))
        }
        let payload = ApprovalPayload(
            instance: instance, macDevice: approver.macDevice, approver: approver.phoneID,
            session: info["sessionId"]?.stringValue ?? sessionID, permission: permissionID, option: optionID, nonce: nonce,
            expiresAt: expiresAt, answers: answers)
        return payload.meta(signature: try sign(payload.message))
    }

    /// Whether a peer could count this phone's signature for `optionID` (acpmux `mac_approvers::may_allow`): the
    /// option offered once, as a one-time allow, of a prompt that is not a plan or a mode switch (each widens
    /// what runs). The peer still checks the rest; this only keeps the phone from asking for a signature that
    /// can never count.
    nonisolated static func peerMayAllow(_ request: JSONValue?, optionID: String) -> Bool {
        let offered = (request?["options"]?.arrayValue ?? []).filter { $0["optionId"]?.stringValue == optionID }
        guard offered.count == 1, offered.first?["kind"]?.stringValue == "allow_once" else { return false }
        let tool = request?["toolCall"]
        let widens = tool?["kind"]?.stringValue == "switch_mode"
            || tool?["_meta"]?["claude"]?["tool"]?.stringValue == "ExitPlanMode"
        return !widens
    }

    /// The approval reason of an answer: the labels (and free text) chosen, so
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

    /// The approval reason of an Allow: the Mac's own title, marked when cut.
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
            toldSinceWatch.insert(session.id)
            let kind = params["recordKind"]?.stringValue ?? params["kind"]?.stringValue ?? ""
            let seq = Int(params["seq"]?.numberValue ?? 0)
            onWatchEvent?(.sessionChanged(session, recordKind: kind, seq: seq))
            if params["kind"]?.stringValue == "permission_resolved" { onWatchEvent?(.permissionResolved(sessionID: session.id)) }
            if params["kind"]?.stringValue == "purged" {
                sessions[session.id] = nil
                purgedSinceWatch.insert(session.id)
            }
        case "_acpmux/permission_pending":
            guard let sessionID, let permissionID = params["permissionId"]?.stringValue, let request = params["request"] else { return }
            onWatchEvent?(.permissionPending(sessionID: sessionID, permissionID: permissionID, request: request))
        case "_acpmux/lagged":
            if (params["dropped"]?.numberValue ?? 0) > 0 { droppedSinceWatch = true }
            // A list reply that went out after a `session_changed` (acpmux `send_serialized`,
            // `list_changed`) dropped nothing: that notice came before it and is applied above,
            // so nothing is read again, neither the list nor an open chat's history. Asking
            // again sent another whole list, which a busy acpmux followed with the same lag: a
            // 25 MB list about every minute without end, which held up the Mac's own chats
            // (2026-11-06; the Mac pane stops the same way, direct.ts `resyncAfterLag`).
            if params["reason"]?.stringValue == "list_changed", (params["dropped"]?.numberValue ?? 0) <= 0 { return }
            // Missed notifications: attached chats fill their gap, and watch runs again. The
            // chats first, before the next notification: a record after the dropped ones must
            // be held for the refill, not applied ahead of it.
            for entry in sources.values { entry.source?.refill() }
            // The watch runs again; its reply is not read, so one row is asked for, not the list.
            Task { [weak self] in
                guard let self, let connection = self.connection else { return }
                _ = try? await connection.request("_acpmux/watch", .object(["enabled": .bool(true), "limit": .number(1)]))
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
    /// The raw records applied to this chat, newest 500 (the Event Inspector).
    let journal = AgentEventJournal()
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
    /// retries (a harness record, never `transcript`), so a retrying turn says so; and its
    /// `bookmarks` record, so a bookmark or pin made on the Mac shows here.
    static let chatKinds: JSONValue = .array(
        ["transcript", "queue_updated", "queue_order", "queue_paused", "queue_resumed", "claude.system.api_retry", "bookmarks"]
            .map { .string($0) })
    /// The sudo card's records (acpmux `hub/elevation.rs`), asked for only from a Mac whose acpmux
    /// serves `elevation-cards-v1`: an older one refuses an attach with more than 8 kinds.
    static let elevationCapability = "elevation-cards-v1"
    static let chatKindsWithElevation: JSONValue = .array(
        (chatKinds.arrayValue ?? []) + [.string("elevation_request"), .string("elevation_decision")])

    /// The kinds this chat's reads ask the Mac for.
    static func kinds(_ hub: AcpmuxHub) -> JSONValue {
        hub.capabilities.contains(elevationCapability) ? chatKindsWithElevation : chatKinds
    }

    init(hub: AcpmuxHub, sessionID: String, summary: AgentSessionSummary) {
        self.hub = hub
        self.sessionID = sessionID
        self.summary = summary
        records = AcpmuxRecords(sessionID: sessionID)
        restoreKept()
        if hub.isReady { linkUp() }
    }

    /// Reads the chat's history before its records come (``AgentSessionSource/loadsHistory``):
    /// until an attach catches up, the chat shows what this phone kept, or a loading state.
    public var loadsHistory: Bool { !attached }

    // MARK: Kept transcript (AgentTranscriptCache)

    /// The chat's key in the phone's transcript cache; nil when it keeps none (no account).
    private var keptKey: String? {
        AgentTranscriptCache.key(accountID: summary.accountID, macID: summary.macID, tabID: summary.id)
    }
    /// The newest records applied, oldest first, from a prompt: what the cache keeps.
    private var kept: [JSONValue] = []
    /// The Mac holds records older than `kept`'s first.
    private var keptEarlier = false
    /// The kept records are being read from disk: the attach waits, so it reads on from them.
    private var restoring = false
    /// The chat shows restored kept records and has not caught up since (``CatchUpRead/fromKept``).
    private var keptRestored = false
    /// Kept records are being applied: their asks are not shown (they may have been answered
    /// since); the attach reply's pending list brings back the ones still open.
    private var applyingKept = false

    /// Shows the records this phone kept for the chat at once (from memory in the same turn,
    /// else after a read off the main thread), so the attach that follows reads only what came
    /// after them (`lastSeq`), as a reattach does.
    private func restoreKept() {
        guard let cache = hub?.transcriptCache, let key = keptKey else { return }
        if let entry = cache.cached(key) {
            restore(entry)
            return
        }
        restoring = true
        Task { [weak self] in
            let entry = await cache.load(key)
            guard let self else { return }
            self.restoring = false
            if let entry { self.restore(entry) }
            if self.hub?.isReady == true { self.linkUp() }
        }
    }

    /// Applies kept records as the chat's history (one batch), when they are this session's and
    /// nothing was applied yet.
    private func restore(_ entry: AgentTranscriptEntry) {
        guard entry.sessionID == sessionID, lastSeq == 0, !attaching, !entry.records.isEmpty else { return }
        log.info("restore \(self.sessionID, privacy: .public): \(entry.records.count, privacy: .public) kept records through \(entry.lastSeq, privacy: .public)")
        beginHistory()
        emit(.earlierHistory(entry.earlier))
        earlierBefore = entry.earlier ? entry.records.first(where: Self.isPrompt)?["seq"]?.numberValue.map { Int($0) } : nil
        earlierCarry = []
        keptEarlier = entry.earlier
        keptRestored = true
        applyingKept = true
        for record in entry.records { apply(record: record) }
        applyingKept = false
        endHistory()
    }

    /// The kept copy is too old to catch up from: this source forgets it and everything it applied,
    /// its readers stop (a store showing the kept turns would otherwise get the newest page on top
    /// of them), the chat's store is rebuilt, and the next read is a first attach.
    private func dropKept() {
        log.info("kept copy of \(self.sessionID, privacy: .public) too old at \(self.lastSeq, privacy: .public): opening on the newest page")
        keptRestored = false
        gapTask?.cancel()
        gapTask = nil
        gapFill = nil
        lastSeq = 0
        replay = []
        openChunk = nil
        openChunkText = ""
        kept = []
        keptEarlier = false
        earlierBefore = nil
        earlierCarry = []
        seenPermissions = []
        listedPermissions = []
        questions = [:]
        if let key = keptKey { hub?.transcriptCache?.forget(key) }
        for continuation in continuations { continuation.finish() }
        continuations = []
        onReset?()
    }

    /// Runs when the source dropped its kept copy (``dropKept()``): the chat's store is built again
    /// on it. Set by the coordinator; tests read it.
    var onReset: (@MainActor () -> Void)?

    /// Records kept in memory past the cache's own bound before they are cut (the cache cuts
    /// its copy again by bytes).
    private var keptLimit: Int { hub?.transcriptCache?.recordLimit ?? 600 }

    private func keep(_ record: JSONValue) {
        guard hub?.transcriptCache != nil, keptKey != nil else { return }
        kept.append(record)
        if kept.count > keptLimit * 2 {
            kept = AgentTranscriptCache.fromPrompt(Array(kept.suffix(keptLimit)))
            keptEarlier = true
        }
    }

    /// Hands the kept records to the cache (it writes them to disk shortly after, bounded).
    private func saveKept() {
        guard let cache = hub?.transcriptCache, let key = keptKey, !kept.isEmpty else { return }
        cache.save(key, sessionID: sessionID, earlier: keptEarlier, records: kept)
    }

    public func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        // What this source already has is history to a new reader: one change, drawn in place.
        flushOpenChunk()
        // A reader made after the attach caught up (a rebuilt store) starts current: the load
        // state goes in the same batch, so the reader gets one change.
        if !replay.isEmpty {
            continuation.yield(.batch(attached ? replay + [.historyLoading(false)] : replay))
        } else if attached {
            continuation.yield(.historyLoading(false))
        }
        continuations.append(continuation)
        return stream
    }

    public func send(_ intent: AgentClientIntent) {
        guard let hub else { return }
        let session = JSONValue.string(sessionID)
        if case .prompt(let text, let attachments, let steer, let promptID, let resend) = intent {
            // Messages reach the Mac in the order they were sent: each waits for the one before
            // it to be written (or held) before its own goes (an upload can take a while).
            let sentAt = now()
            let previous = promptChain
            promptChain = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                let blocks: [JSONValue]
                do {
                    blocks = try await self.promptBlocks(text: text, attachments: attachments, hub: hub)
                } catch {
                    self.emit(.promptNotSent(text: text, attachments: attachments, promptID: promptID,
                                             reason: AcpmuxSessionSource.message(error)))
                    return
                }
                await self.sendPrompt(HeldPrompt(text: text, attachments: attachments, promptID: promptID,
                                                 steer: steer, resend: resend, blocks: blocks, at: sentAt))
            }
            return
        }
        Task {
            do {
                switch intent {
                case .prompt:
                    break // sent above
                case .retryFailedTurn:
                    _ = try await hub.request("_acpmux/retry", .object(["sessionId": session]))
                case .cancel:
                    try await hub.notify("session/cancel", .object(["sessionId": session]))
                case .respondPermission(let permissionID, let optionID):
                    try await hub.respond(sessionID: sessionID, permissionID: permissionID, optionID: optionID)
                case .answerElevation(let ask, let password):
                    try await hub.answerElevation(sessionID: sessionID, ask: ask, password: password)
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

    // MARK: Prompts across a blip

    /// A prompt on its way to the Mac: its blocks (attachments already uploaded) and when it
    /// was sent.
    struct HeldPrompt {
        var text: String
        var attachments: [AgentAttachment]
        var promptID: String
        var steer: Bool
        var resend: Bool
        var blocks: [JSONValue]
        /// When it was sent: its place among the held prompts.
        var at: ContinuousClock.Instant
        /// When it began to wait for the link (its send, or the drop that lost it): its age.
        var waitingSince: ContinuousClock.Instant? = nil
        var waitStart: ContinuousClock.Instant { waitingSince ?? at }
    }

    /// Prompts the link lost or could not take (a blip), oldest first: they go again once
    /// the link is back, in order, each under its own id (acpmux runs a `promptId` once, and
    /// `resend` checks the session log), while younger than ``heldPromptWindow``. Older,
    /// they come back to the composer with what happened (``expireHeldPrompts()``).
    private(set) var heldPrompts: [HeldPrompt] = []
    /// The held prompts are being written to a new link.
    private var flushingHeld = false
    /// How long a prompt may wait for the link before it comes back to the composer: the
    /// terminal's key hold (`DaemonTerminalSession.inputHoldLimit`), so a blip is ridden out
    /// the same way in both (Leo, 2026-11-12, on LTE: "thjs chatters too often with connectivity").
    var heldPromptWindow: Duration = .seconds(10)
    /// The clock prompts are aged on (tests inject one).
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// The last message's send, which the next one waits for (``send(_:)``).
    private var promptChain: Task<Void, Never>?

    /// Sends a prompt now, or after the ones held before it (the Mac gets them in order).
    /// Returns once it is written or held; its answer is awaited apart.
    private func sendPrompt(_ prompt: HeldPrompt) async {
        guard let hub else { return }
        if !heldPrompts.isEmpty || flushingHeld || !hub.isReady {
            hold(prompt)
            return
        }
        let params = Self.promptParams(prompt, session: sessionID)
        do {
            let (connection, id) = try await hub.submit("session/prompt", params)
            Task { [weak self] in await self?.awaitPromptReply(prompt, connection: connection, id: id) }
        } catch {
            promptFailed(prompt, error, written: false)
        }
    }

    static func promptParams(_ prompt: HeldPrompt, session: String) -> JSONValue {
        .object([
            "sessionId": .string(session), "prompt": .array(prompt.blocks),
            "_meta": .object(["acpmux": .object([
                "promptId": .string(prompt.promptID), "steer": .bool(prompt.steer), "resend": .bool(prompt.resend),
            ])]),
        ])
    }

    /// A written prompt's answer (its turn's end); a link that drops first holds it again.
    private func awaitPromptReply(_ prompt: HeldPrompt, connection: AcpmuxConnection, id: Int) async {
        do {
            _ = try await connection.reply(to: id)
        } catch {
            promptFailed(prompt, error, written: true)
        }
    }

    /// The link lost the prompt (it may have reached the Mac: it goes again as a resend, which
    /// acpmux runs at most once), or the Mac refused it (the draft comes back with the reason).
    private func promptFailed(_ prompt: HeldPrompt, _ error: any Error, written: Bool) {
        if !(error is AcpmuxConnection.RPCError) {
            var again = prompt
            if written {
                // It may have run: sent again it is a resend (acpmux checks its log), aged
                // from the drop, not from a send a long turn ago.
                again.resend = true
                again.waitingSince = now()
            }
            hold(again)
            return
        }
        let fullAccess = Self.isFullAccessRefusal(error)
        if fullAccess { hub?.fullAccessRefused() }
        emit(.promptNotSent(text: prompt.text, attachments: prompt.attachments, promptID: prompt.promptID,
                            reason: fullAccess ? AgentChatStore.fullAccessOffPromptNotice : Self.message(error)))
    }

    /// Keeps a prompt for the next link, in the order it was sent; it comes back to the
    /// composer if the link is not back within ``heldPromptWindow`` of its send.
    private func hold(_ prompt: HeldPrompt) {
        let index = heldPrompts.firstIndex { $0.at > prompt.at } ?? heldPrompts.endIndex
        heldPrompts.insert(prompt, at: index)
        guard !expireHeldPrompts() else { return }
        let wait = max(.zero, prompt.waitStart + heldPromptWindow - now())
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.expireHeldPrompts()
        }
        // The next link's `linkUp` writes them; a link that is up now gets them after a short
        // pause (not at once: one that just failed would be written to again in a loop).
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.flushHeldPrompts()
        }
    }

    /// Held prompts older than ``heldPromptWindow``: all of them come back to the composer
    /// (none goes after an earlier one that did not), each with what happened. True when
    /// they did.
    @discardableResult
    private func expireHeldPrompts() -> Bool {
        let window = heldPromptWindow
        let instant = self.now()
        guard heldPrompts.contains(where: { instant - $0.waitStart >= window }) else { return false }
        let dropped = heldPrompts
        heldPrompts = []
        let seconds = max(1, Int(window.components.seconds))
        let reason = "Not sent: \(summary.macName) was unreachable for more than \(seconds) seconds. Send again when it's back."
        log.notice("\(dropped.count, privacy: .public) held prompt(s) of \(self.sessionID, privacy: .public) not sent: the link was down past the window")
        for prompt in dropped {
            emit(.promptNotSent(text: prompt.text, attachments: prompt.attachments, promptID: prompt.promptID, reason: reason))
        }
        return true
    }

    /// Writes the held prompts to the link, oldest first, each once written before the next
    /// (their answers come at their turns' ends, awaited apart). A link that drops again
    /// keeps the rest for the next one.
    func flushHeldPrompts() {
        guard !flushingHeld, !heldPrompts.isEmpty, let hub, hub.isReady else { return }
        flushingHeld = true
        Task { [weak self] in
            while true {
                guard let self, !self.heldPrompts.isEmpty else { break }
                let prompt = self.heldPrompts.removeFirst()
                do {
                    let (connection, id) = try await hub.submit("session/prompt", Self.promptParams(prompt, session: self.sessionID))
                    Task { [weak self] in await self?.awaitPromptReply(prompt, connection: connection, id: id) }
                } catch {
                    self.flushingHeld = false
                    // Not written: held again (first, its order kept), for the next link.
                    self.promptFailed(prompt, error, written: false)
                    return
                }
            }
            self?.flushingHeld = false
            // A send or a `linkUp` that came while this ran is not left waiting.
            self?.flushHeldPrompts()
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
            if attachment.data == nil, attachment.fileURL == nil, let path = attachment.macPath {
                // A recorded video (Retry of an earlier prompt) is on the Mac already: its link goes again.
                uploaded[attachment.id] = path
                continue
            }
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

    // MARK: Chat polish parity

    /// Copy rows and Session Info: `_acpmux/info`, the same read `/status` makes.
    public func sessionDetails() async throws -> AgentSessionDetails {
        let info = try await call("_acpmux/info", ["sessionId": .string(sessionID)])
        return Self.sessionDetails(info, sessionID: sessionID, macName: summary.macName, fallbackHarness: summary.agentName)
    }

    nonisolated static func sessionDetails(_ info: JSONValue, sessionID: String, macName: String, fallbackHarness: String) -> AgentSessionDetails {
        func text(_ value: JSONValue?) -> String? {
            guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        return AgentSessionDetails(
            name: text(info["name"]),
            sessionID: text(info["sessionId"]) ?? sessionID,
            harnessSessionID: text(info["agentSessionId"]) ?? text(info["agent_session_id"]),
            cwd: text(info["cwd"]),
            // A chat on an acpmux peer runs there; otherwise on this Mac (`machine`, its name).
            host: text(info["peer"]) ?? text(info["machine"]) ?? text(info["host"]) ?? macName,
            status: sessionStatus(info, macName: macName, fallbackHarness: fallbackHarness))
    }

    public func bookmarks() async throws -> [Int] {
        Self.marks(try await call("_acpmux/bookmark_get", ["sessionId": .string(sessionID)]))
    }

    public func setBookmark(seq: Int, bookmarked: Bool) async throws -> [Int] {
        Self.marks(try await call("_acpmux/bookmark_set", [
            "sessionId": .string(sessionID), "seq": .number(Double(seq)), "bookmarked": .bool(bookmarked),
        ]))
    }

    nonisolated static func marks(_ reply: JSONValue) -> [Int] {
        (reply["bookmarks"]?.arrayValue ?? []).compactMap { $0.numberValue.map { Int($0) } }
    }

    public func chatPermissions() async throws -> AgentChatPermissions {
        Self.permissions(try await call("_acpmux/permission_groups", ["sessionId": .string(sessionID)]))
    }

    /// `_acpmux/permission_groups`: `chatAllowance.active` and the groups still waiting.
    nonisolated static func permissions(_ reply: JSONValue) -> AgentChatPermissions {
        let open = (reply["groups"]?.arrayValue ?? []).filter { group in
            !["resolved", "cancelled"].contains(group["state"]?.stringValue ?? "")
        }
        return AgentChatPermissions(allowedForChat: reply["chatAllowance"]?["active"] == .bool(true), openGroups: open.count)
    }

    public func revokeChatPermission() async throws {
        let reply = try await call("_acpmux/permission_chat_revoke", ["sessionId": .string(sessionID)])
        // acpmux answers `{active: false}` and nothing else (the Mac's client checks the same).
        guard reply["active"] == .bool(false) else {
            throw AgentFeatureUnavailable(String(localized: "\(summary.macName) didn't confirm the revoke. Refresh and try again."))
        }
    }

    /// Reads the open asks again: a reattach from the last record applied, whose reply lists
    /// every permission still waiting (`applyState`).
    public func refreshPermissions() { refill() }

    public var eventJournal: AgentEventJournal? { journal }

    /// The most records Replay reads (pages of `pageSize`).
    static let replayLimit = 20_000

    /// Replay Conversation: the chat's `transcript` records from its start, as the Mac's replay
    /// reads them (`_acpmux/events {kinds: ["transcript"]}`), mapped to chat events.
    public func replayRecording() async throws -> AgentReplayRecording {
        var records: [JSONValue] = []
        var after = 0
        var more = true
        while more, records.count < Self.replayLimit {
            let page = try await call("_acpmux/events", [
                "sessionId": .string(sessionID), "afterSeq": .number(Double(after)),
                "limit": .number(Double(Self.pageSize)), "kinds": .array([.string("transcript")]),
            ])
            let events = page["events"]?.arrayValue ?? []
            records += events
            guard let newest = events.last?["seq"]?.numberValue else { break }
            after = Int(newest)
            more = page["hasMore"] == .bool(true)
        }
        let mapper = AcpmuxRecords(sessionID: sessionID)
        let steps = records.map { record in
            let events = mapper.map(record)
            let at = record["at"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let isTool = events.contains { event in
                if case .update(.toolCall(_)) = event { return true }
                return false
            }
            return (at: at, events: events, isToolCall: isTool)
        }
        return AgentReplayRecording.build(steps, truncated: more)
    }

    /// One request to this chat's acpmux, its refusal as the Mac's own words.
    private func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        guard let hub, hub.isReady else {
            throw AgentFeatureUnavailable(String(localized: "Agents on \(summary.macName) aren't connected. Try again in a moment."))
        }
        do {
            return try await hub.request(method, .object(params))
        } catch let error as AcpmuxConnection.RPCError {
            throw AgentFeatureUnavailable(error.message)
        } catch {
            throw AgentFeatureUnavailable(Self.message(error))
        }
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
        if error is AcpmuxHub.PeerAllowOnceOnly {
            return "From an iPhone you can allow this other machine's request once, or deny it. Choose Allow once."
        }
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
            case "remote.full_access_required": return AgentChatStore.fullAccessOffNotice
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
        // A gap still filling stays open: the next attach that catches up reads on from
        // where it stopped (`startGapFill`).
        gapTask?.cancel()
        gapTask = nil
        saveKept()
        emit(.status(.disconnected))
        // A chat with history catches up again when the link comes back (a new chat stays new).
        if lastSeq > 0 { emit(.historyLoading(true)) }
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
        // Prompts a blip held go first, in order.
        flushHeldPrompts()
        // Kept records still being read: the attach starts once they are in (`restoreKept`).
        guard !attaching, !restoring, let hub, hub.isReady else { return }
        retryTask?.cancel()
        retryTask = nil
        gapTask?.cancel()
        gapTask = nil
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
        gapTask?.cancel()
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
        /// A reattach may read the newest records first and leave a gap before them: none
        /// is filling now (one gap at a time).
        var allowGap = true
        /// The first catch-up after kept records were restored (``restoreKept()``): a gap longer
        /// than one page means the kept copy is old, and the chat opens fresh instead of paging
        /// through everything since (``CatchUpPages/keptTooOld``).
        var fromKept = false
        var firstAttach: Bool { after == 0 }
    }

    /// A reattach's tail-first read: the newest page starts at `seq`, the prompt of turn
    /// `turnID`, and the records after `after` and before `seq` are still on the Mac.
    struct CatchUpGap: Equatable {
        let after: Int
        let seq: Int
        let turnID: String
    }

    /// What a catch-up read: the attach reply, its records in seq order, whether older ones
    /// exist (a first attach), and the error that stopped it, if one did.
    struct CatchUpPages {
        var result: JSONValue = .null
        var page: [JSONValue] = []
        var earlier = false
        /// Set when `page` is the newest records with a gap before them (tail-first).
        var gap: CatchUpGap?
        var failure: (any Error)?
        /// A catch-up from kept records found more than one page since them: nothing was read past
        /// the attach reply, and the chat opens on its newest page instead (``dropKept()``).
        var keptTooOld = false
    }

    /// The next catch-up of attach `generation`, or nil when it is no longer current.
    private func nextRead(_ generation: Int) -> CatchUpRead? {
        guard generation == self.generation else { return nil }
        refillPending = false
        return CatchUpRead(sessionID: sessionID, after: lastSeq, allowGap: gapFill == nil,
                           fromKept: keptRestored)
    }

    /// The `beforeSeq` of a tail-first reattach: past any seq, so the page is the newest
    /// records after `afterSeq`. 2^40, written as a plain integer (acpmux reads it as a u64).
    static let tailBeforeSeq: Double = 1_099_511_627_776

    /// Where the newest records of a tail-first reattach start: at the first prompt of
    /// `page` (what is before it belongs to a turn in the gap, and is read with it). A
    /// retried attempt's prompt (`auto_resume`) continues the turn before it, so it is no
    /// start. Nil when the page holds no prompt.
    static func tailStart(_ page: [JSONValue], after: Int) -> (index: Int, gap: CatchUpGap)? {
        for (index, record) in page.enumerated() where isPrompt(record) {
            let msg = record["msg"]
            guard msg?["_meta"]?["provenance"]?["kind"]?.stringValue != "auto_resume",
                  let turnID = msg?["turnId"]?.stringValue,
                  let seq = record["seq"]?.numberValue, Int(seq) > after else { continue }
            return (index, CatchUpGap(after: after, seq: Int(seq), turnID: turnID))
        }
        return nil
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
                "kinds": kinds(hub),
                "eventStream": .bool(true),
            ]
            if read.firstAttach {
                params["maxBytes"] = .number(Double(openBytes))
            } else {
                params["afterSeq"] = .number(Double(read.after))
                if read.allowGap, !read.fromKept {
                    // Tail-first: with both cursors acpmux reads the newest `limit` records
                    // between them (`_acpmux/attach`, cmux-tui acpmux server/requests.rs),
                    // capped as an open is, so a reattach after hours away reads what an
                    // open reads, not every record it missed.
                    params["beforeSeq"] = .number(tailBeforeSeq)
                    params["maxBytes"] = .number(Double(openBytes))
                }
                // From kept records the read stays forward: a gap past one page drops the kept
                // copy (`keptTooOld`) instead of filling in behind it.
            }
            out.result = try await request("_acpmux/attach", params)
            let page = out.result["events"]?.arrayValue ?? []
            // A reattach (the link came back, or the Mac said this connection lagged) needs
            // every record after the last one applied, in order. Otherwise the next live record
            // moves `lastSeq` past the rest of the gap, and the chat never sees what was in it (a
            // turn's end, a decision made on the Mac). A page that holds them all (no
            // `hasMore`) is applied as it is. A longer gap is read tail-first: the newest page
            // shows now, and the records before it fill in afterwards (`startGapFill`).
            // Without that (one gap filling already, a Mac that pages forward only, a newest
            // page inside one turn longer than itself) the reattach pages forward from the
            // last record applied until a page reaches the log's end, as it always did.
            if read.fromKept, out.result["hasMore"] == .bool(true) {
                // The kept copy is more than a page behind: open on the newest page instead
                // (``dropKept()``), not on a gap after an old copy.
                out.page = page
                out.keptTooOld = true
                return out
            }
            if !read.firstAttach {
                var more = out.result["hasMore"] == .bool(true)
                var cursor: Double?
                if more, read.allowGap, let first = page.first?["seq"]?.numberValue, Int(first) > read.after + 1,
                   let newest = page.last?["seq"]?.numberValue {
                    // Records are missing before the page. acpmux sent the newest ones (its
                    // `hasMore`: older records after `afterSeq`); a Mac that ignores
                    // `beforeSeq` sent the oldest (`hasMore`: newer ones, written before its
                    // reply's `lastSeq`). One read after the page tells them apart, and is the
                    // forward page either way.
                    let next = try await request("_acpmux/events", [
                        "sessionId": .string(read.sessionID), "afterSeq": .number(newest),
                        "limit": .number(Double(pageSize)), "kinds": kinds(hub),
                    ])
                    let events = next["events"]?.arrayValue ?? []
                    let nextMore = !events.isEmpty && next["hasMore"] == .bool(true)
                    if let after = events.first?["seq"]?.numberValue, Int(after) <= stateSeq(out.result) {
                        out.page = page + events
                        more = nextMore
                    } else if let tail = tailStart(page, after: read.after) {
                        out.page = Array(page[tail.index...]) + events
                        out.gap = tail.gap
                        more = nextMore
                    } else {
                        // The newest page is inside one turn longer than itself: it has no
                        // prompt to start at, so the gap is read forward first.
                        cursor = Double(read.after)
                    }
                } else {
                    out.page = page
                }
                cursor = cursor ?? out.page.last?["seq"]?.numberValue
                while more, let from = cursor {
                    let next = try await request("_acpmux/events", [
                        "sessionId": .string(read.sessionID), "afterSeq": .number(from),
                        "limit": .number(Double(pageSize)), "kinds": kinds(hub),
                    ])
                    let events = next["events"]?.arrayValue ?? []
                    out.page += events
                    cursor = events.last?["seq"]?.numberValue
                    more = !events.isEmpty && next["hasMore"] == .bool(true)
                }
            } else {
                out.page = page
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
        if pages.keptTooOld {
            dropKept()
            return true
        }
        guard apply(pages, read) else {
            attaching = false
            attachTask = nil
            // Live records held meanwhile are newer than the gap: applying them would move
            // `lastSeq` past it for good. The retry reads to the log's end, them included.
            held = []
            scheduleRetry()
            return false
        }
        if let gap = pages.gap { gapFill = GapFill(cursor: gap.after, end: gap.seq) }
        if refillPending { return true }
        attaching = false
        attachTask = nil
        failures = 0
        attached = true
        keptRestored = false
        let pending = held
        held = []
        for record in pending { apply(record: record) }
        startGapFill()
        emit(.historyLoading(false))
        saveKept()
        return false
    }

    // MARK: Reconnect gap (tail-first)

    /// What of a tail-first reattach's gap is still on the Mac: the records after `cursor`
    /// and before `end` (the newest page's first prompt).
    struct GapFill: Equatable {
        var cursor: Int
        let end: Int
    }

    /// The gap being filled, until its last page is in. It outlives a link drop: the next
    /// attach that catches up reads on from `cursor`.
    private(set) var gapFill: GapFill?
    /// The reads filling it, after the newest records showed; cancelled when the link drops
    /// or another attach starts.
    private var gapTask: Task<Void, Never>?
    /// Each gap page's byte cap, as an older page's.
    static let gapBytes = olderBytes

    /// Reads the gap oldest first, one bounded page at a time, while live records go on
    /// arriving (they are newer than anything in it). A page that fails stops the fill; the
    /// next attach that catches up (the link back, a lag) starts it again from `cursor`.
    private func startGapFill() {
        guard gapTask == nil, gapFill != nil, attached, let hub, hub.isReady else { return }
        let generation = generation
        let sessionID = sessionID
        // The task holds the source only between its requests, never across one.
        gapTask = Task { [weak self] in
            while let fill = self?.gapFill, self?.generation == generation, !Task.isCancelled {
                let page: JSONValue
                do {
                    page = try await hub.request("_acpmux/events", .object([
                        "sessionId": .string(sessionID), "afterSeq": .number(Double(fill.cursor)),
                        "limit": .number(Double(Self.pageSize)), "maxBytes": .number(Double(Self.gapBytes)),
                        "kinds": Self.kinds(hub),
                    ]), timeout: Self.pageTimeout)
                } catch {
                    if self?.generation == generation {
                        log.info("gap \(sessionID, privacy: .public) after \(fill.cursor, privacy: .public): page failed, waits for the next attach")
                        self?.gapTask = nil
                    }
                    return
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.applyGap(page, fill)
            }
            if self?.generation == generation { self?.gapTask = nil }
        }
    }

    /// Sends one gap page to the chat: its records before the gap's end, in order, each once.
    private func applyGap(_ page: JSONValue, _ fill: GapFill) {
        guard gapFill == fill else { return }
        let events = page["events"]?.arrayValue ?? []
        var cursor = fill.cursor
        var done = events.isEmpty || page["hasMore"] != .bool(true)
        var gapRecords: [JSONValue] = []
        for record in events {
            guard let number = record["seq"]?.numberValue else { continue }
            let seq = Int(number)
            if seq >= fill.end {
                done = true
                break
            }
            guard seq > cursor else { continue }
            gapRecords.append(record)
            cursor = seq
        }
        // A page that moves nothing on while promising more would be read forever.
        if !done, cursor == fill.cursor { done = true }
        gapFill = done ? nil : GapFill(cursor: cursor, end: fill.end)
        var mapped: [AgentSessionEvent] = []
        for record in gapRecords {
            for event in records.map(record) {
                switch event {
                case .permissionRequest(let request):
                    // Shown already (still open, from the attach reply's list): not twice.
                    guard seenPermissions.insert(request.id).inserted else { continue }
                case .question(let question):
                    questions[question.id] = question
                    guard seenPermissions.insert(question.id).inserted else { continue }
                default:
                    break
                }
                mapped.append(event)
            }
        }
        log.info("gap \(self.sessionID, privacy: .public) after \(fill.cursor, privacy: .public): \(gapRecords.count, privacy: .public) records, through \(cursor, privacy: .public), done \(done, privacy: .public)")
        // A later reader of this source gets the gap's records where they belong: before
        // the marker, which goes once the gap is filled.
        flushOpenChunk()
        if let marker = replay.lastIndex(where: { if case .gapOpened = $0 { true } else { false } }) {
            replay.insert(contentsOf: mapped, at: marker)
            if done { replay.remove(at: marker + mapped.count) }
        }
        guard !mapped.isEmpty || done else { return }
        for continuation in continuations { continuation.yield(.gapPage(mapped, done: done)) }
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
            // A tail-first page has a gap before it: applied without its gap it would move
            // `lastSeq` past the gap for good. The retry reads it tail-first again.
            guard !read.firstAttach, pages.gap == nil, !page.isEmpty else { return false }
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
            kept = []
            keptEarlier = pages.earlier
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
        // Tail-first: the turns the chat has, then a gap, then these newest records.
        if let gap = pages.gap {
            emit(.gapOpened(beforeTurnID: gap.turnID))
            // The gap's records reach the chat but not the kept copy (`applyGap`): the kept
            // copy starts again at these newest records, with older ones on the Mac, so a
            // restore never shows the turns before the gap joined to these with nothing between.
            kept = []
            keptEarlier = true
        }
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
                    "limit": .number(Double(pageSize)), "maxBytes": .number(Double(olderBytes)), "kinds": kinds(hub),
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
        flushOpenChunk()
        if !events.isEmpty { replay.insert(contentsOf: events, at: 0) }
        yieldEarlier(events, hasEarlier: hasEarlier)
    }

    private func yieldEarlier(_ events: [AgentSessionEvent], hasEarlier: Bool) {
        flushOpenChunk()
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
        // A turn's start and end are where the kept transcript is saved (not every streamed chunk).
        if let kind = record["kind"]?.stringValue, kind == "user_message" || kind == "turn_result" { saveKept() }
    }

    /// A record in order: one already applied (its seq at most `lastSeq`) is skipped.
    private func apply(record: JSONValue) {
        let seq = Int(record["seq"]?.numberValue ?? 0)
        guard seq == 0 || seq > lastSeq else { return }
        if seq > 0 {
            lastSeq = seq
            keep(record)
        }
        journal.record(record)
        for event in records.map(record) {
            switch event {
            case .permissionRequest, .question:
                if applyingKept { continue }
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
        for event in events { record(replay: event) }
        for continuation in continuations { continuation.yield(.batch(events)) }
    }

    private func emit(_ event: AgentSessionEvent) {
        switch event {
        case .clientError, .promptNotSent, .historyLoading:
            // Not history: a later reader learns the load state from `events()` itself.
            break
        default:
            if history != nil {
                history?.append(event)
                return
            }
            record(replay: event)
        }
        for continuation in continuations { continuation.yield(event) }
    }

    /// Keeps `event` for a later reader. A streamed reply arrives as one chunk per few
    /// tokens, and the buffer kept each one for as long as the chat stayed open (tens of
    /// thousands of events for one long turn). Consecutive chunks of one message, or of
    /// one thought, are kept as a single chunk with their text joined: `AgentChatStore`
    /// appends a chunk of the same message to it, so a reader draws the same transcript
    /// and the buffer grows with messages, not tokens.
    private func record(replay event: AgentSessionEvent) {
        switch (openChunk, event) {
        case (.message(let id)?, .update(.agentMessageChunk(let text, let nextID))) where id == nextID:
            openChunkText += text
        case (.thought?, .update(.agentThoughtChunk(let text))):
            openChunkText += text
        default:
            flushOpenChunk()
            switch event {
            case .update(.agentMessageChunk(let text, let id)):
                openChunk = .message(id)
                openChunkText = text
            case .update(.agentThoughtChunk(let text)):
                openChunk = .thought
                openChunkText = text
            default:
                replay.append(event)
            }
        }
    }

    /// The chunk being joined, kept out of `replay` so its text grows in place.
    private enum OpenChunk { case message(String?), thought }
    private var openChunk: OpenChunk?
    private var openChunkText = ""

    private func flushOpenChunk() {
        guard let chunk = openChunk else { return }
        switch chunk {
        case .message(let id): replay.append(.update(.agentMessageChunk(text: openChunkText, messageId: id)))
        case .thought: replay.append(.update(.agentThoughtChunk(text: openChunkText)))
        }
        openChunk = nil
        openChunkText = ""
    }

    /// How many events the source keeps for a later reader (tests).
    var replayCount: Int { replay.count + (openChunk == nil ? 0 : 1) }
}
