import CmuxAgentQuestion
import CmuxConnectivityTelemetry
import CmuxMobileAgentChat
import CmuxMobileArtifacts
#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import enum CmuxMobileModel.UserFacingError
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

/// The chat prompt outboxes' clock (``ChatPromptOutbox``'s `nowMs`): milliseconds on the
/// continuous clock from a fixed origin well before any instant the app or a test passes.
enum ChatPromptClock {
    static let origin = ContinuousClock.now - .seconds(10_000_000)

    static func milliseconds(_ instant: ContinuousClock.Instant) -> UInt64 {
        milliseconds(instant - origin)
    }

    static func milliseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        return UInt64(seconds) * 1000 + UInt64(attoseconds / 1_000_000_000_000_000)
    }

    static func instant(_ milliseconds: UInt64) -> ContinuousClock.Instant {
        origin + .milliseconds(Int64(clamping: milliseconds))
    }
}

/// The app's acpmux client for the connected Mac. It outlives links: each
/// new link binds a fresh `acpmux` channel, runs `initialize` and
/// `_acpmux/watch`, and re-attaches every open chat from its last seq.
@MainActor
@Observable
public final class AcpmuxHub {
    /// Every chat the watch reported, newest page first (`AcpmuxHub+SessionPages.swift`): ready
    /// with the first page, the rest read after it.
    public internal(set) var sessions: [String: AcpmuxSession] = [:] { didSet { listRevision &+= 1 } }
    /// Moves on every change of `sessions`: a list acpmux orders (`CloudChatList`) reads its page again.
    public private(set) var listRevision = 0
    public private(set) var isReady = false
    /// A failure binding the channel (shown in diagnostics).
    public private(set) var lastError: String?
    /// The link the channel rides on (artifact previews open `file` channels on it).
    @ObservationIgnored public var macLink: (any MacLink)?
    /// The Mac link's last progress (``MacSession/progress``), told by every channel bound here;
    /// nil: each channel keeps its own.
    @ObservationIgnored public var linkProgress: LinkProgress?

    @ObservationIgnored var connection: AcpmuxConnection?
    /// Recovers this hub's channel when a read stalls on it (`AcpmuxHub+Steady.swift`): the live
    /// coordinator opens a fresh `acpmux` channel on the same link and binds it. Nil: no recovery,
    /// a stalled read fails at its deadline as before.
    @ObservationIgnored public var onStall: (@MainActor () async -> Void)?
    /// The person sent something on this hub (every prompt passes through ``submit(_:_:)``): a
    /// Cloud chat reports it as wake on intent's input (`CloudWakeOnIntent`).
    @ObservationIgnored public var onSubmit: (@MainActor () -> Void)?
    /// The one recovery running now; every stalled read waits on it rather than starting its own.
    @ObservationIgnored var recovering: Task<Void, Never>?
    /// Requests ride out a reconnect (wait for the next ready channel) and retry an idempotent read
    /// once on a fresh channel. False: the old behavior, failing at once (the bench's baseline).
    @ObservationIgnored var steadyReads = true
    /// How long a request waits for a channel that is coming back before it says offline.
    @ObservationIgnored var readyGrace: Duration = AcpmuxHub.defaultReadyGrace
    /// How long a read may go unanswered before the channel counts as stalled and is replaced.
    @ObservationIgnored var stallAfter: Duration = AcpmuxHub.defaultStallAfter
    @ObservationIgnored var steadyClock: any Clock<Duration> = ContinuousClock()
    /// The fixed part of a prompt write's bound (``AcpmuxConnection/writeBound(bytes:base:)``; tests shorten it).
    @ObservationIgnored var writeBase: Duration = AcpmuxConnection.writeBase
    /// Callers of `waitUntilReady` (a Feed answer whose Mac's link is opening).
    @ObservationIgnored private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [String: [WeakSource]] = [:]
    /// Sessions this phone started (New Task, New Agent Chat), newest last: their chat's
    /// loading state says "Starting <agent>…" until its first records, not "Loading chat…".
    @ObservationIgnored private(set) var startedHere: [String] = []

    func forgetStartedHere(_ sessionID: String) { startedHere.removeAll { $0 == sessionID } }

    /// Sessions whose first message this phone is sending (New Task), until that send ends
    /// (its turn finished, or it failed). Observed: the chat leaves its starting state with it.
    private(set) var firstPromptsInFlight: [String] = []
    func beginFirstPrompt(_ sessionID: String) {
        // Bounded, the oldest going first (a send whose reply never comes).
        firstPromptsInFlight.removeAll { $0 == sessionID }
        firstPromptsInFlight.append(sessionID)
        if firstPromptsInFlight.count > 32 { firstPromptsInFlight.removeFirst(firstPromptsInFlight.count - 32) }
    }
    func endFirstPrompt(_ sessionID: String) { firstPromptsInFlight.removeAll { $0 == sessionID } }

    /// Notes a session this phone started (`session/new`); the newest 32 are kept.
    func noteStartedHere(_ sessionID: String) {
        startedHere.removeAll { $0 == sessionID }
        startedHere.append(sessionID)
        if startedHere.count > 32 { startedHere.removeFirst(startedHere.count - 32) }
    }
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
    /// Whether an `initialize` from this Mac has answered since launch: until then
    /// `capabilities` is unknown, not empty (``pipelineAttaches``).
    @ObservationIgnored private var capabilitiesKnown = false
    /// This connection's compact chunks and row patches, read back into whole records and rows
    /// (``AcpmuxDeltas``); a new one per connection, as the Mac keeps its side per connection.
    @ObservationIgnored var deltas = AcpmuxDeltas()
    /// The connection a row gap already recovered (``rowGap(_:)``): the gaps after the first on
    /// it wait for that recovery, never start another.
    @ObservationIgnored private weak var rowGapRecovered: AcpmuxConnection?
    /// Catch-up attaches answered from the write beside `initialize` (``pipelineAttaches``).
    @ObservationIgnored var pipelinedAttachesRead = 0

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
    /// A chat with an expired replay cache may still have an open reader. Keep routing
    /// to it while a new reader loads its own complete snapshot from the Mac.
    private var liveSources: [AcpmuxSessionSource] {
        sources.values.flatMap { $0.compactMap(\.source) }
    }

    public init() {}

    /// Binds a new `acpmux` channel (nil unbinds after a link drop).
    /// `gate`: a channel opened behind `auth` before its pairing finished. `initialize` and the first
    /// page go out at once (the Mac holds them until pairing passes, so they ride beside its last
    /// round trip), but nothing the Mac sends is applied, and no reply's timeout starts, until
    /// `gate` says this phone's own check of the Mac passed; when it fails the channel just closes.
    public func bind(_ channel: (any LinkChannel)?, requestTimeout: Duration = .seconds(20),
                     until gate: (@Sendable () async -> Bool)? = nil) async {
        pumpTask?.cancel()
        restOfList?.cancel()
        restOfList = nil
        toldSinceWatch = []
        purgedSinceWatch = []
        droppedSinceWatch = false
        listWhole = false
        deltas = AcpmuxDeltas()
        if let old = connection { Task { await old.close() } }
        connection = nil
        isReady = false
        lastError = nil
        fullAccess = false
        for source in liveSources { source.linkDown() }
        guard let channel else { return }
        let connection = AcpmuxConnection(channel: channel, held: gate != nil, progress: linkProgress ?? LinkProgress())
        self.connection = connection
        await connection.start()
        let notifications = connection.notifications
        pumpTask = Task { [weak self] in
            // Notifications wait, bounded, in the connection until the pairing passed (`admit`).
            if let gate, !(await gate()) { return }
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
            for source in self.liveSources { source.linkDown() }
        }
        do {
            // `initialize` and the first page go out together: acpmux answers a connection's
            // requests in order and the page needs nothing from `initialize`, so the chat list is
            // one round trip away, not two (ask-48f698fc26). The newest page only (CMUX-563): a
            // Mac with hundreds of chats sent its whole list (megabytes) before the phone was
            // ready. The rest is read after ready, below.
            let initializeID = try await connection.submit("initialize", .object([
                "protocolVersion": .number(1),
                "clientInfo": .object(["name": .string("cmux-ios"), "version": .string("1")]),
                "clientCapabilities": .object([:]),
                // Streamed text and row changes in their compact forms (`AcpmuxDeltas`), and no time
                // breakdown: the phone draws none in any attach or chat row on this connection (acpmux
                // `server/requests/time_breakdown_gate.rs`). A Mac that predates a key ignores it and
                // sends that part whole, as before.
                "_meta": .object(["acpmux": .object(AcpmuxDeltas.initializeMeta.merging(["omitTimeBreakdown": .bool(true)]) { $1 })]),
            ]), timeout: requestTimeout)
            let pageID = try await connection.submit("_acpmux/watch", Self.firstPageParams, timeout: requestTimeout)
            // Each open chat's catch-up attach goes in the same burst (acpmux answers in order,
            // after `initialize`), so a resumed chat is one round trip from its page, not two.
            await pipelineAttaches(connection, timeout: requestTimeout)
            if let gate, !(await gate()) {
                // The pairing failed: nothing this Mac sent is applied, and nothing is said here
                // (the pairing says why).
                if self.connection === connection { self.connection = nil }
                await connection.close()
                return
            }
            await connection.admit()
            let initialized = try await Self.reply(connection, initializeID, "initialize", timeout: requestTimeout)
            personInstance = initialized["_meta"]?["acpmux"]?["personInstance"]?.stringValue
            fullAccess = initialized["_meta"]?["acpmux"]?["fullAccess"] == .bool(true)
            capabilities = Set((initialized["_meta"]?["acpmux"]?["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue))
            capabilitiesKnown = true
            let page = try await Self.reply(connection, pageID, "_acpmux/watch", timeout: requestTimeout)
            let first = (rows: try AcpmuxConnection.pageRows(page), cursor: try AcpmuxConnection.nextCursor(page))
            guard !(await connection.isClosed), self.connection === connection else { return }
            let firstPage = applyFirstPage(first.rows, whole: first.cursor == nil)
            let firstIDs = firstPage.ids
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
            for source in liveSources { source.linkUp() }
            if firstPage.changed {
                onWatchEvent?(.sessionsLoaded(Array(next.values)))
            }
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
            for source in liveSources { source.linkDown() }
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

    /// Writes each open chat's first catch-up attach right behind `initialize` and the watch,
    /// with the kinds the last connection to this Mac allowed (`capabilities` stays until this
    /// connection's `initialize` answers). The chat's catch-up reads that reply instead of asking
    /// again (``AcpmuxSessionSource/readPages``); when `initialize` names other kinds, or the
    /// chat's cursor moved, the reply is dropped and the attach is asked as before. On the first
    /// connection since launch (no kinds known yet) it asks for every kind the phone draws: a
    /// current Mac answers that, so the cold open's chat is one round trip from its page, not
    /// two; an older one refuses it or names fewer kinds, and the attach is asked again as
    /// before. A Mac whose `initialize` named no capabilities gets none (an old Mac).
    private func pipelineAttaches(_ connection: AcpmuxConnection, timeout: Duration) async {
        guard !capabilities.isEmpty || !capabilitiesKnown else { return }
        let kinds = capabilitiesKnown ? AcpmuxSessionSource.kinds(self) : AcpmuxSessionSource.chatKindsWithElevation
        for source in liveSources {
            guard let params = source.pipelineAttachParams(kinds: kinds),
                  let id = try? await connection.submit("_acpmux/attach", .object(params), timeout: timeout)
            else { continue }
            source.notePipelined(.init(connection: connection, id: id, params: params))
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

    /// A request on the current channel. While the channel is coming back it waits for it
    /// (``readyGrace``); an idempotent read that stalls or loses its channel is retried once on a
    /// fresh one (`AcpmuxHub+Steady.swift`), so a blip never reaches the person as an error.
    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await steady(method, stallWatch: true) { try await $0.request(method, params) }
    }

    public func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await steady(method, stallWatch: true) { try await $0.request(method, params, timeout: timeout) }
    }

    /// One request on the channel as it is: no wait, no retry, no recovery. For probes of the
    /// channel itself (the Feed's Retry), which must not recover the channel they test.
    public func requestOnce(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let connection else { throw LinkError(code: "offline", message: "Not connected to the Mac") }
        return try await connection.request(method, params, timeout: timeout)
    }

    /// ``AcpmuxConnection/wholeList(_:_:timeout:)`` on the current connection. A long list
    /// takes as long as it takes (no stall watch); a lost channel is retried once.
    public func wholeList(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> [JSONValue] {
        try await steady(method, stallWatch: false) { try await $0.wholeList(method, params, timeout: timeout) }
    }

    /// ``AcpmuxConnection/submit(_:_:)`` on the current connection: returns once the request
    /// is written, with the connection that answers it. Waits for a channel that is coming back;
    /// never retried (a submit is a send).
    public func submit(_ method: String, _ params: JSONValue) async throws -> (AcpmuxConnection, Int) {
        onSubmit?()
        let connection = try await readyConnection()
        return (connection, try await connection.submit(method, params, base: writeBase))
    }

    public func notify(_ method: String, _ params: JSONValue) async throws {
        let connection = try await liveConnection()
        try await connection.notify(method, params)
    }

    /// Reuse a complete replay; after its budget expires, a new reader gets a fresh
    /// attach instead of a suffix whose first deltas have no message to append to.
    public func source(sessionID: String, summary: AgentSessionSummary) -> AcpmuxSessionSource {
        let existing = (sources[sessionID] ?? []).compactMap(\.source)
        if let source = existing.last(where: { !$0.replay.requiresResync }) { return source }
        let source = AcpmuxSessionSource(hub: self, sessionID: sessionID, summary: summary)
        sources[sessionID] = (existing + [source]).map { WeakSource(source: $0) }
        return source
    }

    // A retained source can have readers using a freshly attached replay generation.
    // Session actions must reach them as well as readers of the original generation.
    fileprivate func emitLocal(_ event: AgentSessionEvent, sessionID: String) {
        for entry in sources[sessionID] ?? [] { entry.source?.receiveLocal(event) }
    }

    fileprivate func refreshPermissions(sessionID: String) {
        for entry in sources[sessionID] ?? [] { entry.source?.refill() }
    }

    fileprivate func loadEarlierHistory(sessionID: String) {
        for entry in sources[sessionID] ?? [] { entry.source?.loadEarlierHistoryPage() }
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
        for source in liveSources { source.fullAccessChanged(false) }
    }

    private func handle(_ notification: AcpmuxConnection.Notification) {
        // Anything heard from the Mac is the link making progress: a prompt waiting its turn
        // keeps going rather than coming back at a fixed 10 s (Leo, 2026-11-24).
        for source in liveSources { source.linkProgressed() }
        let params = notification.params
        let sessionID = params["sessionId"]?.stringValue
        switch notification.method {
        case "_cmux/prompt_resend":
            // The Mac's outbox resends a prompt it holds for this phone: Rust turns the notice
            // into the chat's look (retrying) or its end (refused).
            if let sessionID {
                for entry in sources[sessionID] ?? [] { entry.source?.receive(promptResend: params) }
            }
        case "_acpmux/event":
            let params = deltas.event(params)
            if let sessionID {
                for entry in sources[sessionID] ?? [] { entry.source?.receive(record: params) }
            }
        case "_acpmux/chunk":
            switch deltas.chunk(params) {
            case let .event(sessionID, params):
                for entry in sources[sessionID] ?? [] { entry.source?.receive(record: params) }
            case .unknownRef:
                // Its full event never came here (dropped, or from before this connection), and a
                // compact chunk does not say whose it is: every open chat reads on from its last
                // record, as for a lag. Attaching again has the Mac send the next chunk whole.
                ConnectivityTelemetry.shared.record(.hub, "chunk_unknown_ref", outcome: .failure)
                for source in liveSources { source.refill() }
            }
        case "_acpmux/session_patch":
            switch deltas.patch(params) {
            case let .changed(changed):
                sessionChanged(changed)
            case let .gap(sessionID):
                rowGap(sessionID)
            }
        case "_acpmux/session_changed":
            sessionChanged(deltas.changed(params))
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
            for source in liveSources { source.refill() }
            // The watch runs again; its reply is not read, so one row is asked for, not the list.
            Task { [weak self] in
                guard let self, let connection = self.connection else { return }
                _ = try? await connection.request("_acpmux/watch", .object(["enabled": .bool(true), "limit": .number(1)]))
            }
        default:
            break
        }
    }

    /// A chat's row, whole (`session_changed`, or a patch applied to the row held).
    private func sessionChanged(_ params: JSONValue) {
        guard let value = params["session"], let session = AcpmuxSession(value) else { return }
        let kind = params["recordKind"]?.stringValue ?? params["kind"]?.stringValue ?? ""
        let changed = kind == "purged" || sessions[session.id] != session
        sessions[session.id] = session
        toldSinceWatch.insert(session.id)
        let seq = Int(params["seq"]?.numberValue ?? 0)
        if changed {
            onWatchEvent?(.sessionChanged(session, recordKind: kind, seq: seq))
        }
        if params["kind"]?.stringValue == "permission_resolved" { onWatchEvent?(.permissionResolved(sessionID: session.id)) }
        if params["kind"]?.stringValue == "purged" {
            sessions[session.id] = nil
            purgedSinceWatch.insert(session.id)
        }
    }

    /// A patch whose base is not the row held: the Mac and this phone no longer agree on what
    /// the phone holds, and only a new connection resets the Mac's side (its rows go whole
    /// again). The channel is recovered once, as for a stalled read (one recovery for every gap
    /// that came on it); until then the row shown stays the last one applied. A hub with nothing
    /// to recover its channel (``onStall`` nil: Cloud chats, tests) keeps that row until the
    /// chat's next whole row (an attach, a detach).
    private func rowGap(_ sessionID: String) {
        ConnectivityTelemetry.shared.record(.hub, "row_patch_gap", outcome: .failure)
        guard let connection, onStall != nil, rowGapRecovered !== connection else { return }
        rowGapRecovered = connection
        Task { [weak self] in
            await self?.recover(from: connection, why: "row_gap", method: "_acpmux/session_patch")
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
    private var continuations: [UUID: AsyncStream<AgentSessionEvent>.Continuation] = [:]
    /// Readers whose stream is still open (``events()``): a chat closing ends its stream, and
    /// with none left nothing waits for an older page (``readerLeft()``).
    private var readers = 0
    fileprivate var replay = AcpmuxReplay<AgentSessionEvent>(limit: AcpmuxSessionSource.replayEventLimit)
    private var lastSeq = 0
    /// The `timeBreakdownVersion` of the last attach reply: sent back on the next attach, so a
    /// reopen with nothing new is not sent the chat's whole `timeBreakdown` again (cmux-tui
    /// acpmux `server/requests/time_breakdown_gate.rs`). The phone does not read the breakdown.
    private var timeBreakdownVersion: String?
    private var attached = false
    /// The phone started this session moments ago (``AcpmuxHub/noteStartedHere(_:)``).
    public var isStarting: Bool { hub?.startedHere.contains(sessionID) == true }
    public var awaitsFirstPrompt: Bool { hub?.firstPromptsInFlight.contains(sessionID) == true }
    /// The hub's link to the Mac is down (it is reconnecting): observed through `isReady`.
    public var isOffline: Bool { hub?.isReady != true }
    private var attaching = false
    /// Records that arrive while attaching are applied after the attach page.
    private var held: [JSONValue] = []
    private var questions: [String: AgentQuestion] = [:]
    /// The raw records applied to this chat, newest 500 (the Event Inspector).
    let journal = AgentEventJournal()
    /// Replay is a cache, independent of how the Mac pages history.
    /// Keep enough room for a tail-first reattach's bounded pages and their record metadata.
    /// A prompt and result each add a sequence marker to the replay, so a 300-turn gap can
    /// legitimately exceed two thousand events even though it is only three wire pages.
    /// The cache remains bounded; once this budget is exhausted a later reader resyncs.
    static let replayEventLimit = 4_096
    /// The most records one history read returns.
    static let pageSize = 400
    /// The open's byte cap, as the Mac's agent pane opens: a long chat draws its newest records
    /// after one small read. It used to read 2000 records in five round trips first (1.3-4.3 MB
    /// on the Mac's long chats), and a page that timed out threw the whole read away.
    static let openBytes = 128 * 1024
    /// Each older page's byte cap (``loadEarlierHistory()``, as the reader scrolls up).
    static let olderBytes = 256 * 1024
    /// A tool call record past this goes in a page with its output cut to its head
    /// (`toolOutputMaxBytes`, cmux-tui acpmux `hub/tool_output_cut.rs`), and is read whole when
    /// the person opens the output (``fullToolOutput(_:)``). A page always carries its records
    /// whole, so one 2 MB command log was a page nine times its byte cap, on the wire and in the
    /// parse. An older Mac ignores it and sends the record whole, as before.
    static let toolOutputMaxBytes = 64 * 1024
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
        // The newest kept turns from the head file in this turn, so the reopened chat's first
        // frame draws them; the whole kept copy is read off the main thread only to keep saving
        // it whole (its older turns come from the Mac as the reader scrolls up, as for any page).
        if let head = cache.firstScreen(key) {
            restore(head)
            guard head.earlier, keptRestored else { return }
            let headSeq = head.lastSeq
            Task { [weak self] in
                guard let whole = await cache.load(key), let self, self.keptRestored, whole.sessionID == self.sessionID,
                      whole.lastSeq == headSeq, whole.records.count > head.records.count else { return }
                let newer = self.kept.filter { Int($0["seq"]?.numberValue ?? 0) > headSeq }
                self.kept = whole.records + newer
                self.keptEarlier = whole.earlier
            }
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
        heldEarlier = nil
        keptEarlier = entry.earlier
        keptRestored = true
        applyingKept = true
        for record in entry.records { apply(record: record) }
        applyingKept = false
        endHistory()
    }

    /// The kept copy is too old to catch up from, or a reattach's hole is too wide to read
    /// (``CatchUpPages/holeTooWide``): this source forgets it and everything it applied, its
    /// readers stop (a store showing the held turns would otherwise get the newest page on top
    /// of them), the chat's store is rebuilt, and the next read is a first attach.
    private func dropKept() {
        log.info("held records of \(self.sessionID, privacy: .public) too far behind at \(self.lastSeq, privacy: .public): opening on the newest page")
        keptRestored = false
        gapTask?.cancel()
        gapTask = nil
        gapFill = nil
        lastSeq = 0
        replay = AcpmuxReplay<AgentSessionEvent>(limit: Self.replayEventLimit)
        openChunk = nil
        openChunkText = ""
        kept = []
        keptEarlier = false
        earlierBefore = nil
        earlierCarry = []
        stopEarlier()
        seenPermissions = []
        listedPermissions = []
        questions = [:]
        if let key = keptKey { hub?.transcriptCache?.forget(key) }
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
        readers = 0
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
        let (head, rest) = makeEvents(holdHead: false)
        assert(head.isEmpty)
        return rest
    }

    /// The kept replay as the head, applied by the store in its init so a kept chat's first
    /// frame has its turns (before, the store took them one main-actor hop later and the first
    /// frame could be "Loading chat…").
    public func eventsWithHead() -> (head: [AgentSessionEvent], rest: AsyncStream<AgentSessionEvent>) {
        makeEvents(holdHead: true)
    }

    private func makeEvents(holdHead: Bool) -> (head: [AgentSessionEvent], rest: AsyncStream<AgentSessionEvent>) {
        var head: [AgentSessionEvent] = []
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        // Flushing can exhaust the cache: decide whether to resync afterwards.
        flushOpenChunk()
        if replay.requiresResync {
            guard let hub else {
                continuation.yield(.clientError("Reconnect to load this chat."))
                continuation.finish()
                return (head, stream)
            }
            let source = hub.source(sessionID: sessionID, summary: summary)
            let upstream = source.events()
            let task = Task {
                defer { withExtendedLifetime(source) {} }
                for await event in upstream { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            return (head, stream)
        }
        // A reader made after the attach caught up starts current in the same batch.
        let first: AgentSessionEvent? = !replay.events.isEmpty
            ? .batch(attached ? replay.events + [.historyLoading(false)] : replay.events)
            : attached ? .historyLoading(false) : nil
        if let first {
            if holdHead { head = [first] } else { continuation.yield(first) }
        }
        let id = UUID()
        continuations[id] = continuation
        readers += 1
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(forKey: id)
                self?.readerLeft()
            }
        }
        return (head, stream)
    }

    /// A reader's stream ended (its chat closed, or ``dropKept()`` ended it): with no reader left,
    /// the older read on the wire is cancelled and the page held ahead is let go. A chat that
    /// opens again asks for its own.
    private func readerLeft() {
        readers -= 1
        guard readers <= 0 else { return }
        readers = 0
        stopEarlier()
    }

    public func send(_ intent: AgentClientIntent) {
        guard let hub else { return }
        if case .prompt(let text, let attachments, let steer, let promptID, let resend) = intent {
            // Messages reach the Mac in the order they were sent: each waits for the one before
            // it to be written (or held) before its own goes (an upload can take a while).
            let sentAt = now()
            // One trace id from the tap to the Mac's write of the prompt (``PhoneTrace``).
            let traceID = PhoneTrace.newTraceID()
            let previous = promptChain
            // The files already uploading since their pick go with this prompt; emptying the
            // composer after Send does not cancel them.
            let prestaged = prestager.claim(attachments)
            let task = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                defer { self.sendTasks[promptID] = nil }
                let blocks: [JSONValue]
                do {
                    try Task.checkCancellation()
                    blocks = try await PhoneTrace.$traceID.withValue(traceID) {
                        try await PhoneTrace.action("send-attachments", args: ["count": "\(attachments.count)"]) {
                            try await self.promptBlocks(text: text, attachments: attachments, promptID: promptID, hub: hub,
                                                        prestaged: prestaged)
                        }
                    }
                    try Task.checkCancellation()
                } catch {
                    // Stopped or failed before every early upload was linked: none of them is wanted now.
                    for entry in prestaged.values { entry.task.cancel() }
                    let reason = error is CancellationError ? "Not sent: you stopped it." : AcpmuxSessionSource.message(error)
                    self.emit(.promptNotSent(text: text, attachments: attachments, promptID: promptID, reason: reason))
                    return
                }
                await self.sendPrompt(HeldPrompt(text: text, attachments: attachments, promptID: promptID,
                                                 steer: steer, resend: resend, blocks: blocks, at: sentAt, traceID: traceID))
            }
            promptChain = task
            sendTasks[promptID] = task
            return
        }
        // Every message on its way has an exit, at every stage: before the outbox has it, its
        // upload is cancelled; once it has it, Rust says how to take it back (`stopPrompt`).
        switch intent {
        case .cancelSend(let promptID):
            sendTasks[promptID]?.cancel()
            stopPrompt(promptID, delete: false)
            return
        case .deleteSend(let promptID):
            sendTasks[promptID]?.cancel()
            stopPrompt(promptID, delete: true)
            return
        case .retrySend(let promptID):
            retryPromptNow(promptID)
            return
        default:
            break
        }
        Task {
            // A call the link lost (a timeout, a dropped channel) waits for the link and goes once
            // more; only one that still can't reach the Mac past ``heldPromptWindow`` says so, as
            // the chat's one quiet line (never the link's own words in a toast).
            var waitedForLink = false
            let stoppedTurn = self.runningTurnID
            while true {
                do {
                    try await self.perform(intent, hub: hub)
                    return
                } catch {
                    if Self.isTransient(error) {
                        if case .cancel = intent,
                           !Self.stopStillApplies(pressedFor: stoppedTurn, running: self.runningTurnID) { return }
                        if !waitedForLink, await hub.waitUntilReady(timeout: self.heldPromptWindow, clock: ContinuousClock()) {
                            waitedForLink = true
                            if case .cancel = intent,
                               !Self.stopStillApplies(pressedFor: stoppedTurn, running: self.runningTurnID) { return }
                            continue
                        }
                        self.emitLocal(.clientError(AgentChatStore.unreachableNotice))
                        return
                    }
                    if AcpmuxSessionSource.isFullAccessRefusal(error) { hub.fullAccessRefused() }
                    self.emitLocal(.clientError(AcpmuxSessionSource.message(error)))
                    return
                }
            }
        }
    }

    /// A failure the link heals on its own: nothing for a person to read or do
    /// (``LinkError/isTransient``, a cancelled wait, a socket that dropped).
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? LinkError { return error.isTransient }
        if error is CancellationError || error is URLError { return true }
        return false
    }

    /// One non-prompt intent, sent once.
    private func perform(_ intent: AgentClientIntent, hub: AcpmuxHub) async throws {
        let session = JSONValue.string(sessionID)
        switch intent {
        case .prompt, .cancelSend, .deleteSend, .retrySend:
            break // handled above
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
                self.emitLocal(.clientError("This question is no longer open on \(self.summary.macName)."))
                return
            }
            try await hub.answer(question, with: answer)
        case .setModel(let id):
            _ = try await hub.request("session/set_model", .object(["sessionId": session, "modelId": .string(id)]))
            // The menu's check follows the pick (no record carries the model change).
            if !self.knownModels.isEmpty { self.emitLocal(.modelsAvailable(self.knownModels, current: id)) }
        case .retryWithModel(let model, let text, let attachments, let promptID):
            // As the Mac's Retry with another model: the move first; a refusal (acpmux's
            // own words, e.g. a Claude chat the Mac started) sends nothing.
            _ = try await hub.request("session/set_model", .object(["sessionId": session, "modelId": .string(model)]))
            if !self.knownModels.isEmpty { self.emitLocal(.modelsAvailable(self.knownModels, current: model)) }
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
    }

    // MARK: Prompts across a blip

    /// A prompt on its way to the Mac: its blocks (attachments already uploaded) and when it
    /// was sent. What goes, when and as what is the Rust outbox's (``promptOutbox``); this is
    /// what is written once it says so.
    struct HeldPrompt {
        var text: String
        var attachments: [AgentAttachment]
        var promptID: String
        var steer: Bool
        var resend: Bool
        var blocks: [JSONValue]
        /// When it was sent: its place among the held prompts.
        var at: ContinuousClock.Instant
        /// The send's trace id (``PhoneTrace``), sent as `_meta.traceId`.
        var traceID: String = PhoneTrace.newTraceID()
    }

    /// How long a prompt may go with no progress on the link (nothing heard from the Mac, no
    /// write taken) before the chat marks it not sent: a stall bound, long enough that a resume,
    /// a network switch or a slow first link never reaches the person (Leo, 2026-11-12, on LTE:
    /// "thjs chatters too often with connectivity"; 2026-11-22: "i dont wanna see connecting to
    /// cosmic-gray... with the spinner, i want it to just work").
    var heldPromptWindow: Duration = AgentChatStore.sendDeadline {
        didSet {
            #if canImport(CmuxMobileLinkFFI)
            promptOutbox.setHoldMs(holdMs: ChatPromptClock.milliseconds(heldPromptWindow))
            #endif
        }
    }
    /// The outbox's default quiet window: Rust's `chat_prompt_default_hold_ms` where the FFI links
    /// (iOS); a build without it (the macOS host build of the package) has no outbox, and takes the
    /// same 30 s the Rust test pins.
    static var defaultHeldPromptWindow: Duration {
        #if canImport(CmuxMobileLinkFFI)
        .milliseconds(Int64(clamping: chatPromptDefaultHoldMs()))
        #else
        .seconds(30)
        #endif
    }
    /// The clock prompts are aged on (tests inject one).
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    /// The last message's upload, which the next one waits for (``send(_:)``).
    private var promptChain: Task<Void, Never>?
    /// Each prompt the outbox holds, by its `promptId`: what to write when it goes.
    private var promptPayloads: [String: HeldPrompt] = [:]
    /// Each message's send until it is written or held, by prompt id: Stop cancels its upload.
    private var sendTasks: [String: Task<Void, Never>] = [:]
    /// The composer's files, uploading to the Mac since they were picked (``prestageAttachments(_:)``).
    private let prestager = AttachmentPrestager()

    #if canImport(CmuxMobileLinkFFI)
    /// The chat's prompts until the Mac answers them (Rust, `cmux_composer_send::chat`): one
    /// `promptId` per prompt for every attempt, a resend once a written one's answer was lost
    /// (acpmux runs a `promptId` once and checks its log), one write at a time in send order,
    /// retried with a jittered, capped backoff, queued while the link is down and given back
    /// past ``heldPromptWindow``. This source only writes what it hands out and reports back.
    private let promptOutbox = ChatPromptOutbox(holdMs: ChatPromptClock.milliseconds(AgentChatStore.sendDeadline), seed: UInt64.random(in: 0...UInt64.max))
    /// The wake for the outbox's next hold or retry.
    private var promptWake: Task<Void, Never>?

    /// Prompts the link lost or could not take (a blip), oldest first: they go again once the
    /// link is back, in order, while younger than ``heldPromptWindow``; older, they come back to
    /// the composer with what happened.
    var heldPrompts: [HeldPrompt] {
        promptOutbox.unwritten().compactMap { promptPayloads[$0] }
    }

    /// Hands a prompt (its attachments uploaded) to the outbox, which writes it now or after the
    /// ones before it (the Mac gets them in order).
    private func sendPrompt(_ prompt: HeldPrompt) async {
        guard hub != nil else { return }
        let nowMs = ChatPromptClock.milliseconds(now())
        promptPayloads[prompt.promptID] = prompt
        _ = promptOutbox.push(promptId: prompt.promptID, text: prompt.text, uploadIds: [], resend: prompt.resend,
                              tappedMs: ChatPromptClock.milliseconds(prompt.at), nowMs: nowMs)
        pumpPrompts()
    }

    /// Does what the outbox says is due: gives back prompts past the hold, writes the next one,
    /// and wakes for the next hold or retry.
    private func pumpPrompts() {
        guard let hub else { return }
        let nowMs = ChatPromptClock.milliseconds(now())
        promptOutbox.setLink(up: hub.isReady, nowMs: nowMs)
        promptsGaveUp(promptOutbox.expire(nowMs: nowMs))
        if let request = promptOutbox.nextRequest(nowMs: nowMs) {
            if var prompt = promptPayloads[request.promptId] {
                prompt.resend = request.resend
                Task { [weak self] in await self?.writePrompt(prompt, hub: hub) }
            } else {
                _ = promptOutbox.answered(promptId: request.promptId)
            }
        }
        schedulePromptWake(nowMs)
        publishPendingSends(nowMs)
    }

    /// The pending rows last told to the chat.
    private var shownPendingSends: [AgentPendingSend] = []

    /// Tells the chat the rows of the prompts on their way, as the outbox draws them (shown ones
    /// only, with the actions each has), when they changed.
    private func publishPendingSends(_ nowMs: UInt64) {
        let rows = promptOutbox.pendingSends(nowMs: nowMs).filter(\.shown).map {
            AgentPendingSend(promptID: $0.promptId, text: $0.text, waiting: $0.look == .retrying,
                             canSendNow: $0.canSendNow, stopping: $0.stopping)
        }
        guard rows != shownPendingSends else { return }
        shownPendingSends = rows
        emit(.pendingSends(rows))
    }

    /// Stop (`delete` false: its text comes back to the composer, to edit and send again) or
    /// Delete a prompt the outbox holds, at any stage. Rust says which: one that never left is
    /// back at once; one that may be on the Mac is never sent again and is taken off the Mac's
    /// queue first (too late when its turn already started: it shows as it runs).
    private func stopPrompt(_ promptID: String, delete: Bool) {
        let held = promptPayloads[promptID]
        let step = delete ? promptOutbox.delete(promptId: promptID) : promptOutbox.cancel(promptId: promptID)
        switch step {
        case .returned(let done)?:
            promptPayloads[promptID] = nil
            promptStopped(promptID, text: held?.text ?? done.text, attachments: held?.attachments ?? [], delete: delete)
        case .removeOnMac(let id)?:
            Task { [weak self] in
                guard let self, let hub = self.hub else { return }
                var removed = false
                do {
                    let reply = try await hub.request("_acpmux/queue_remove", .object([
                        "sessionId": .string(self.sessionID), "promptId": .string(id),
                    ]))
                    removed = reply["removed"] == .bool(true)
                } catch {
                    self.emitLocal(.clientError(AcpmuxSessionSource.message(error)))
                }
                let done = self.promptOutbox.removeAnswered(promptId: id, removed: removed)
                self.promptPayloads[id] = nil
                if removed, done == nil || done?.outcome == .cancelled {
                    self.promptStopped(id, text: held?.text ?? done?.text ?? "", attachments: held?.attachments ?? [], delete: delete)
                } else if !delete {
                    self.emitLocal(.clientError("Too late to stop: \(self.summary.macName) already started it."))
                }
                self.pumpPrompts()
            }
        case nil:
            break
        }
        pumpPrompts()
    }

    /// A stopped prompt comes back to the composer; a deleted one is gone (the chat dropped its row).
    private func promptStopped(_ promptID: String, text: String, attachments: [AgentAttachment], delete: Bool) {
        emit(.promptNotSent(text: delete ? "" : text, attachments: delete ? [] : attachments, promptID: promptID,
                            reason: "Not sent: you stopped it."))
    }

    /// Send now: a prompt waiting on a retry goes at once (Rust decides whether it may).
    private func retryPromptNow(_ promptID: String) {
        if promptOutbox.retryNow(promptId: promptID, nowMs: ChatPromptClock.milliseconds(now())) {
            pumpPrompts()
        }
    }

    private func writePrompt(_ prompt: HeldPrompt, hub: AcpmuxHub) async {
        do {
            let (connection, id) = try await Self.tracedSubmit(prompt, session: sessionID, hub: hub)
            promptOutbox.wrote(promptId: prompt.promptID)
            promptOutbox.progressed(nowMs: ChatPromptClock.milliseconds(now()))
            pumpPrompts()
            do {
                _ = try await connection.reply(to: id)
                _ = promptOutbox.answered(promptId: prompt.promptID)
                promptPayloads[prompt.promptID] = nil
            } catch {
                promptFailed(prompt, error, written: true)
            }
        } catch {
            promptFailed(prompt, error, written: false)
        }
        pumpPrompts()
    }

    private func schedulePromptWake(_ nowMs: UInt64) {
        promptWake?.cancel()
        // A row's look changing (a prompt starting to wait) wakes it too, to redraw its row.
        let waits = [promptOutbox.nextWakeMs(nowMs: nowMs), promptOutbox.nextLookChangeMs(nowMs: nowMs)].compactMap { $0 }
        guard let wait = waits.min() else { promptWake = nil; return }
        promptWake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(clamping: wait)))
            guard !Task.isCancelled else { return }
            self?.pumpPrompts()
        }
    }

    /// The link lost the prompt (it may have reached the Mac: it goes again as a resend, which
    /// acpmux runs at most once), or the Mac refused it (the draft comes back with the reason).
    private func promptFailed(_ prompt: HeldPrompt, _ error: any Error, written: Bool) {
        let nowMs = ChatPromptClock.milliseconds(now())
        guard let rpc = error as? AcpmuxConnection.RPCError else {
            if written {
                promptOutbox.lost(promptId: prompt.promptID, nowMs: nowMs)
            } else {
                promptOutbox.writeFailed(promptId: prompt.promptID, nowMs: nowMs)
            }
            return
        }
        // Rust decides: a "not now" goes again after its backoff (1 s doubling to 30 s) and is
        // not given back; only a real refusal fails, with acpmux's own text.
        switch promptOutbox.refusal(promptId: prompt.promptID, origin: rpc.origin, code: rpc.dataCode,
                                    reason: rpc.reason, nowMs: nowMs) {
        case .retry?, nil:
            return
        case .final?:
            break
        }
        promptPayloads[prompt.promptID] = nil
        let fullAccess = Self.isFullAccessRefusal(error)
        if fullAccess { hub?.fullAccessRefused() }
        emit(.promptNotSent(text: prompt.text, attachments: prompt.attachments, promptID: prompt.promptID,
                            reason: fullAccess ? AgentChatStore.fullAccessOffPromptNotice : Self.message(error)))
    }

    /// Prompts the outbox gave back past the hold: each comes back to the composer with what
    /// happened (none went after an earlier one that did not).
    private func promptsGaveUp(_ done: [ChatPromptDone]) {
        guard !done.isEmpty else { return }
        // One quiet line on each bubble (the chat marks it not sent; a tap sends it again).
        let reason = AgentChatStore.unreachableNotice
        log.notice("\(done.count, privacy: .public) held prompt(s) of \(self.sessionID, privacy: .public) not sent: the link was down past the window")
        for prompt in done {
            guard let held = promptPayloads.removeValue(forKey: prompt.promptId) else { continue }
            emit(.promptNotSent(text: held.text, attachments: held.attachments, promptID: held.promptID, reason: reason))
        }
    }

    /// The link is back (or a prompt waits): what is due goes, in order.
    func flushHeldPrompts() {
        pumpPrompts()
    }

    /// The Mac's `_cmux/prompt_resend` notice (`promptId`, `state`: sent | accepted | retrying |
    /// refused, `retryInMs`, `message`): Rust changes the prompt's look; a refusal gives it back.
    func receive(promptResend params: JSONValue) {
        guard let promptID = params["promptId"]?.stringValue, let state = params["state"]?.stringValue else { return }
        let nowMs = ChatPromptClock.milliseconds(now())
        let retryIn = params["retryInMs"]?.numberValue.map { UInt64(max($0, 0)) }
        if promptOutbox.resendNotice(promptId: promptID, state: state, retryInMs: retryIn, nowMs: nowMs) != nil,
           let held = promptPayloads.removeValue(forKey: promptID) {
            let reason = params["message"]?.stringValue ?? params["reason"]?.stringValue ?? "Not sent."
            emit(.promptNotSent(text: held.text, attachments: held.attachments, promptID: held.promptID, reason: reason))
        }
        pumpPrompts()
    }

    /// The link dropped: prompts wait for the next one.
    private func promptLinkDown() {
        promptOutbox.setLink(up: false, nowMs: ChatPromptClock.milliseconds(now()))
        pumpPrompts()
    }
    #else
    /// Without the Rust outbox (the macOS test build): no prompt is held.
    var heldPrompts: [HeldPrompt] { [] }

    private func sendPrompt(_ prompt: HeldPrompt) async {
        guard let hub else { return }
        do {
            let (connection, id) = try await Self.tracedSubmit(prompt, session: sessionID, hub: hub)
            Task { [weak self] in
                do { _ = try await connection.reply(to: id) } catch { self?.promptNotSent(prompt, error) }
            }
        } catch {
            promptNotSent(prompt, error)
        }
    }

    private func promptNotSent(_ prompt: HeldPrompt, _ error: any Error) {
        let fullAccess = Self.isFullAccessRefusal(error)
        if fullAccess { hub?.fullAccessRefused() }
        emit(.promptNotSent(text: prompt.text, attachments: prompt.attachments, promptID: prompt.promptID,
                            reason: fullAccess ? AgentChatStore.fullAccessOffPromptNotice : Self.message(error)))
    }

    func flushHeldPrompts() {}
    func receive(promptResend params: JSONValue) {}
    private func promptLinkDown() {}
    private func stopPrompt(_ promptID: String, delete: Bool) {}
    private func retryPromptNow(_ promptID: String) {}
    #endif

    /// Writes the prompt as the `send` action of its trace (``PhoneTrace``): the span ends when the
    /// Mac's channel took it, one round trip at the floor; the answer comes when the turn ends.
    static func tracedSubmit(_ prompt: HeldPrompt, session: String, hub: AcpmuxHub) async throws -> (AcpmuxConnection, Int) {
        try await PhoneTrace.$traceID.withValue(prompt.traceID) {
            try await PhoneTrace.action("send", floorRoundTrips: 1, args: ["resend": "\(prompt.resend)"]) {
                try await hub.submit("session/prompt", promptParams(prompt, session: session))
            }
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

    /// acpmux's refusal of what the Mac's mobile host sent marked `requireFullAccess` for this
    /// phone (`server/remote_guard.rs`): its Full-access setting does not cover it.
    nonisolated static func isFullAccessRefusal(_ error: any Error) -> Bool {
        (error as? AcpmuxConnection.RPCError)?.reason == "remote.full_access_required"
    }

    /// This phone's Full-access setting, for the chat's mode menus.
    func fullAccessChanged(_ on: Bool) { emit(.fullAccess(on)) }

    /// When the link's last progress was told to the outbox: told at most every quarter second.
    private var progressToldMs: UInt64 = 0

    /// The link made progress (a message from the Mac, a write taken): the outbox's hold
    /// bounds a stall, so prompts waiting their turn keep going (Rust decides; this only tells).
    func linkProgressed() {
        #if canImport(CmuxMobileLinkFFI)
        let nowMs = ChatPromptClock.milliseconds(now())
        guard nowMs >= progressToldMs + 250, !promptPayloads.isEmpty else { return }
        progressToldMs = nowMs
        promptOutbox.progressed(nowMs: nowMs)
        schedulePromptWake(nowMs)
        #endif
    }

    /// The composer's attachments changed: files a prompt would upload start uploading now, into the
    /// same folder Send uploads to; files taken off stop (``AttachmentPrestager``).
    public func prestageAttachments(_ attachments: [AgentAttachment]) {
        let cwd = baseDirectory
        let macName = summary.macName
        var upload: AttachmentPrestager.Upload?
        if let link: any MacLink = hub?.macLink {
            upload = { @Sendable (payload: LinkUpload.Payload, name: String) async throws -> String in
                try await AcpmuxSessionSource.upload(payload, name: name, cwd: cwd, link: link, macName: macName)
            }
        }
        prestager.sync(attachments, upload: upload)
    }

    /// ACP prompt content: the text, then per attachment
    /// - an image: an `image` block (base64 data and its MIME type);
    /// - a file: uploaded to the Mac over the link's `upload` service into the
    ///   session's folder (`.cmux/attachments`, next to acpmux's own), then a
    ///   `resource` block with its text when it is UTF-8 text up to 256 KiB, or
    ///   a `resource_link` to the uploaded path (the agent reads it there).
    /// A failed upload throws, so nothing is sent without its attachments.
    /// Each upload shows on the message as it starts (``AgentSessionEvent/promptUploading(promptID:_:)``).
    /// Its bounds, resume and byte progress are the upload engine's (`AttachmentUploadClient`,
    /// lane/ios-attachment-send).
    func promptBlocks(text: String, attachments: [AgentAttachment], promptID: String, hub: AcpmuxHub,
                      prestaged: [String: AttachmentPrestager.Entry] = [:]) async throws -> [JSONValue] {
        let progress: @Sendable (AgentUploadProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.emit(.promptUploading(promptID: promptID, step)) }
        }
        return try await Self.promptBlocks(text: text, attachments: attachments, link: hub.macLink, cwd: baseDirectory,
                                           macName: summary.macName, progress: progress, prestaged: prestaged)
    }

    /// A prompt's content for any session in `cwd`, without a chat source: PDFs inline when
    /// they fit, other files uploaded to `cwd` (or the Mac's uploads folder) and linked.
    static func promptBlocks(text: String, attachments: [AgentAttachment], link: (any MacLink)?, cwd: String?,
                             macName: String, progress: (@Sendable (AgentUploadProgress) -> Void)? = nil,
                             prestaged: [String: AttachmentPrestager.Entry] = [:]) async throws -> [JSONValue] {
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
            if let early = prestaged[attachment.id], let path = await Self.prestagedPath(early, attachment: attachment, progress: progress) {
                uploaded[attachment.id] = path
                continue
            }
            try Task.checkCancellation()
            guard let link else { throw LinkError(code: "offline", message: "Connect to \(macName) to send \(attachment.name).") }
            progress?(AgentUploadProgress(name: attachment.name, sent: 0, total: attachment.byteCount ?? attachment.data?.count ?? 0,
                                          phase: .opening, attempt: 1))
            uploaded[attachment.id] = try await Self.upload(payload, name: attachment.name, cwd: cwd, link: link, macName: macName)
        }
        // Base64 of PDFs and video frames (megabytes) is made off the main actor.
        return await Task.detached(priority: .userInitiated) {
            Self.promptBlocks(text: text, attachments: attachments, uploaded: uploaded, inlineDocuments: inline)
        }.value
    }

    /// The Mac path of a file that began uploading when it was picked, once that upload ends; nil
    /// when it failed (Send uploads the file afresh). Stopping the send stops the upload. Logs how
    /// long Send waited and the file's pick-to-available time (`upload` category).
    static func prestagedPath(_ early: AttachmentPrestager.Entry, attachment: AgentAttachment,
                              progress: (@Sendable (AgentUploadProgress) -> Void)?) async -> String? {
        let waitStart = ContinuousClock.now
        progress?(AgentUploadProgress(name: attachment.name, sent: 0, total: attachment.byteCount ?? attachment.data?.count ?? 0,
                                      phase: .opening, attempt: 1))
        let task = early.task
        let path = await withTaskCancellationHandler {
            try? await task.value
        } onCancel: {
            task.cancel()
        }
        let end = ContinuousClock.now
        AttachmentPrestager.log.info("prestage send waited_ms=\(AttachmentPrestager.ms(end - waitStart)) pick_to_available_ms=\(AttachmentPrestager.ms(end - early.started)) ok=\(path != nil)")
        return path
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
    public func refreshPermissions() {
        hub?.refreshPermissions(sessionID: sessionID)
    }

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
        let ready: Bool
        if let hub { ready = hub.isReady ? true : await hub.waitUntilReady(timeout: hub.readyGrace, clock: ContinuousClock()) } else { ready = false }
        guard let hub, ready else {
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

    /// The whole record of a tool output the Mac sent cut (``ACPToolOutputCut``): that one seq,
    /// read with no cut, decoded off the main actor. Nil when the link is down, the read fails or
    /// the record is no tool call; the next open of the output asks again.
    public func fullToolOutput(_ cut: ACPToolOutputCut) async -> ACPToolCallUpdate? {
        guard cut.seq > 0, let hub, hub.isReady else { return nil }
        guard let reply = try? await hub.request("_acpmux/events", .object([
            "sessionId": .string(sessionID), "afterSeq": .number(Double(cut.seq - 1)), "limit": .number(1),
        ]), timeout: Self.pageTimeout),
              let record = reply["events"]?.arrayValue?.first,
              record["seq"]?.numberValue == Double(cut.seq) else { return nil }
        let mapper = records
        return await Task.detached(priority: .userInitiated) { mapper.toolCallUpdate(in: record) }.value
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
            // The chat clears this notice by its exact text when full access turns on.
            if error.reason == "remote.full_access_required" { return AgentChatStore.fullAccessOffNotice }
            // An agent's own refusal ("model unavailable") says what is wrong in the chat;
            // a dump (a type name, JSON) or an empty message falls through to the type's copy.
            let raw = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if error.reason == nil, !raw.hasPrefix("no pending permission"), UserFacingError.displayable(raw) != nil {
                return TurnFailureCopy.plain(raw)
            }
            // RPCError's copy (reasons, "Already answered", an agent's JSON error) lives on the type.
            if let text = error.errorDescription { return text }
        }
        return LinkController.reason(error)
    }

    func linkDown() {
        // An attach still waiting on the old connection ends without touching this chat.
        generation += 1
        dropPipelined()
        attachTask?.cancel()
        attachTask = nil
        retryTask?.cancel()
        retryTask = nil
        failures = 0
        attached = false
        attaching = false
        refillPending = false
        held = []
        // A gap still filling stays open: the next attach that catches up reads it whole,
        // from its start (`startGapFill`).
        gapTask?.cancel()
        gapTask = nil
        saveKept()
        emit(.status(.disconnected))
        // A chat with history catches up again when the link comes back (a new chat stays new).
        if lastSeq > 0 { emit(.historyLoading(true)) }
        // Only a connection's own `initialize` says Full access covers it (`attach` sends it again).
        fullAccessChanged(false)
        promptLinkDown()
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
            var pipelined = self?.takePipelined()
            while let read = self?.nextRead(generation) {
                // A chat's first read is the "open-chat" action (``PhoneTrace``): its pages are
                // its round trips; one, the pipelined attach, is the floor.
                let pages = await PhoneTrace.action(read.firstAttach ? "open-chat" : "catch-up", floorRoundTrips: 1) {
                    await Self.readPages(hub, read, pipelined: pipelined) { [weak self] in self?.generation == generation }
                }
                pipelined = nil
                guard self?.caughtUp(pages, read, generation) == true else { return }
            }
        }
    }

    isolated deinit {
        attachTask?.cancel()
        retryTask?.cancel()
        gapTask?.cancel()
        earlierTask?.cancel()
        earlierRetryTask?.cancel()
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

    /// A first catch-up attach written with `initialize` and the watch (``AcpmuxHub/bind``),
    /// whose reply the catch-up reads instead of asking again.
    struct PipelinedAttach: Sendable {
        let connection: AcpmuxConnection
        let id: Int
        let params: [String: JSONValue]
        /// Not read: its reply is taken and let go, so the connection keeps nothing for it.
        func drop() {
            let (connection, id) = (connection, id)
            Task { _ = try? await connection.reply(to: id) }
        }
    }
    /// Set from the write until the catch-up takes it; records that come meanwhile are held.
    private var pipelined: PipelinedAttach?

    /// The attach the next catch-up would send now, to write with `initialize` and the watch;
    /// nil when the chat would not attach at once (an attach running, kept records loading).
    func pipelineAttachParams(kinds: JSONValue) -> [String: JSONValue]? {
        guard !attaching, !restoring, hub != nil else { return nil }
        let read = CatchUpRead(sessionID: sessionID, after: lastSeq, allowGap: gapFill == nil,
                               fromKept: keptRestored, timeBreakdownVersion: timeBreakdownVersion)
        return Self.attachParams(read, kinds: kinds)
    }

    func notePipelined(_ attach: PipelinedAttach) {
        pipelined?.drop()
        pipelined = attach
    }

    private func takePipelined() -> PipelinedAttach? {
        defer { pipelined = nil }
        return pipelined
    }

    private func dropPipelined() {
        pipelined?.drop()
        pipelined = nil
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
        /// The breakdown copy the last attach named (``AcpmuxSessionSource/timeBreakdownVersion``).
        var timeBreakdownVersion: String?
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
        /// A reattach found the hole between the records the chat holds and the newest ones wider
        /// than ``bridgeMaxSeqs``: it is not read. The held turns go (``dropKept()``), and `page`,
        /// the newest records from a prompt, opens the chat as a first attach's would, with older
        /// history from scrolling up. An empty `page`: the chat is read again as a first attach.
        var holeTooWide = false
    }

    /// The widest hole a reattach reads to join the records the chat holds to the newest ones: one
    /// page's records. A narrower hole is read whole and goes in at once (`startGapFill`). A wider
    /// one (hours away from a busy chat) is not read: the chat opens on its newest page, as a first
    /// open does (`holeTooWide`). Reading it forward page by page drew each page in turn above the
    /// newest turn, so everything above it moved again and again while the chat waited on all of
    /// them (Leo, 2026-11-17, on the Mac's agent pane, the same reconnect). Constant cost, whatever
    /// was missed.
    static let bridgeMaxSeqs = pageSize
    /// The most seqs a reattach reads forward past its first page: a hole of ``bridgeMaxSeqs``
    /// and a page past it (the newest page is read forward when it starts inside a turn), and
    /// what was written meanwhile. A reattach that needs more (a Mac that pages only forward, or
    /// one gap filling already, after a long time away) opens fresh (`holeTooWide`), as a wide
    /// hole does, instead of reading everything it missed.
    static let forwardMaxSeqs = 2 * bridgeMaxSeqs

    /// The next catch-up of attach `generation`, or nil when it is no longer current.
    private func nextRead(_ generation: Int) -> CatchUpRead? {
        guard generation == self.generation else { return nil }
        refillPending = false
        return CatchUpRead(sessionID: sessionID, after: lastSeq, allowGap: gapFill == nil,
                           fromKept: keptRestored, timeBreakdownVersion: timeBreakdownVersion)
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
    private static func readPages(_ hub: AcpmuxHub, _ read: CatchUpRead, pipelined: PipelinedAttach? = nil,
                                  current: @escaping () -> Bool) async -> CatchUpPages {
        var out = CatchUpPages()
        func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
            guard current(), !Task.isCancelled else { throw CancellationError() }
            return try await hub.request(method, .object(params), timeout: pageTimeout)
        }
        do {
            let params = attachParams(read, kinds: kinds(hub))
            if let pipelined, pipelined.params == params, pipelined.connection === hub.connection, current(),
               let reply = try? await AcpmuxHub.reply(pipelined.connection, pipelined.id, "_acpmux/attach", timeout: pageTimeout) {
                // Written with `initialize` and the watch (``AcpmuxHub/pipelineAttaches``). A Mac
                // that refused it (an older one, other kinds) is asked again below.
                hub.pipelinedAttachesRead += 1
                out.result = reply
            } else {
                pipelined?.drop()
                out.result = try await request("_acpmux/attach", params)
            }
            // `out` keeps what was read before a failed page: the chat applies it and reads on
            // from its last record, not again from the cursor.
            try await readRest(hub, read, &out, request)
        } catch {
            out.failure = error
        }
        return out
    }

    /// The first catch-up's `_acpmux/attach` params for `read`, asking for `kinds`.
    static func attachParams(_ read: CatchUpRead, kinds: JSONValue) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "sessionId": .string(read.sessionID),
            "limit": .number(Double(pageSize)),
            "kinds": kinds,
            "eventStream": .bool(true),
        ]
        if let version = read.timeBreakdownVersion {
            params["timeBreakdownVersion"] = .string(version)
            // The phone draws no breakdown: once the daemon has named a version (it knows the
            // field), ask it to leave the breakdown out even after new turns changed it.
            params["omitTimeBreakdown"] = .bool(true)
        }
        if read.firstAttach {
            params["maxBytes"] = .number(Double(openBytes))
            params["toolOutputMaxBytes"] = .number(Double(toolOutputMaxBytes))
        } else {
            params["afterSeq"] = .number(Double(read.after))
            if read.allowGap, !read.fromKept {
                // Tail-first: with both cursors acpmux reads the newest `limit` records
                // between them (`_acpmux/attach`, cmux-tui acpmux server/requests.rs),
                // capped as an open is, so a reattach after hours away reads what an
                // open reads, not every record it missed.
                params["beforeSeq"] = .number(tailBeforeSeq)
                params["maxBytes"] = .number(Double(openBytes))
                params["toolOutputMaxBytes"] = .number(Double(toolOutputMaxBytes))
            }
            // From kept records the read stays forward: a gap past one page drops the kept
            // copy (`keptTooOld`) instead of filling in behind it.
        }
        return params
    }

    /// An attach reply whose page holds every record of the kinds asked through the log's end
    /// (`pageThrough` at least `lastSeq`, cmux-tui acpmux server/requests.rs
    /// `page_reaches_end`): the chat is current with no read after it. An older Mac that sends
    /// no `pageThrough`, or one short of `lastSeq`, is read after as before.
    static func pageReachesEnd(_ result: JSONValue) -> Bool {
        guard let through = result["pageThrough"]?.numberValue, let last = result["lastSeq"]?.numberValue else { return false }
        return through >= last
    }

    /// The rest of a catch-up after its attach reply (`out.result`), into `out` as it reads, so
    /// a page that fails leaves the pages before it in place.
    private static func readRest(_ hub: AcpmuxHub, _ read: CatchUpRead, _ out: inout CatchUpPages,
                                 _ request: (String, [String: JSONValue]) async throws -> JSONValue) async throws {
        let page = out.result["events"]?.arrayValue ?? []
        // A reattach (the link came back, or the Mac said this connection lagged) needs
        // every record after the last one applied, in order. Otherwise the next live record
        // moves `lastSeq` past the rest of the gap, and the chat never sees what was in it (a
        // turn's end, a decision made on the Mac). A page that holds them all (no
        // `hasMore`) is applied as it is. A longer gap is read tail-first: the newest page
        // shows now, and the records before it go in at once when all are read
        // (`startGapFill`); a gap wider than ``bridgeMaxSeqs`` is not read, and the chat
        // opens on the newest page (`holeTooWide`). Without a gap (one gap filling already, a
        // Mac that pages forward only, a newest page inside one turn longer than itself) the
        // reattach pages forward from the last record applied to the log's end, at most
        // ``forwardMaxSeqs`` on; past that it opens on the newest page too.
        if read.fromKept, out.result["hasMore"] == .bool(true) {
            // The kept copy is more than a page behind: open on the newest page instead
            // (``dropKept()``), not on a gap after an old copy.
            out.page = page
            out.keptTooOld = true
            return
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
                // forward page either way; a page that says it reaches the end
                // (`pageReachesEnd`, a current Mac) needs none.
                let next: JSONValue = pageReachesEnd(out.result)
                    ? .object(["events": .array([]), "hasMore": .bool(false)])
                    : try await request("_acpmux/events", [
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
                    more = nextMore
                    if tail.gap.seq - read.after - 1 > bridgeMaxSeqs {
                        // Too wide to read: the page opens the chat (`holeTooWide`).
                        out.holeTooWide = true
                    } else {
                        out.gap = tail.gap
                    }
                } else if Int(first) - read.after - 1 > bridgeMaxSeqs {
                    // The newest page is inside one turn longer than itself, past a hole too
                    // wide to read: the chat opens again as a first attach, which reads that
                    // turn's prompt.
                    out.holeTooWide = true
                    return
                } else {
                    // The newest page is inside one turn longer than itself: it has no
                    // prompt to start at, so the gap is read forward first.
                    cursor = Double(read.after)
                }
            } else {
                out.page = page
            }
            cursor = cursor ?? out.page.last?["seq"]?.numberValue
            let loopStart = cursor.map { Int($0) } ?? read.after
            while more, let from = cursor {
                if Int(from) - loopStart > forwardMaxSeqs {
                    // Still not at the log's end (`forwardMaxSeqs`): the rest is not read
                    // either. The chat opens again as a first attach.
                    out.page = []
                    out.gap = nil
                    out.holeTooWide = true
                    return
                }
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
            } else if let opener = out.result["turnOpener"], Self.isPrompt(opener),
                      let seq = opener["seq"]?.numberValue {
                // acpmux read the turn's prompt with the page (cmux-tui
                // `requests/turn_opener.rs`): the page has its turn with no read of its own.
                // An older Mac sends none (or null when its read found none): the read below.
                out.page = [opener] + out.page
                out.earlier = seq > 1
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
    }

    /// Applies a catch-up's pages. False when it caught up or ended (failed: a retry is
    /// scheduled; stale: nothing is applied); true when it must read again first: the Mac
    /// dropped records while it read (`refill`), and the held records may come after one it
    /// dropped. Applying them would move `lastSeq` past the dropped one for good.
    private func caughtUp(_ pages: CatchUpPages, _ read: CatchUpRead, _ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        if let version = pages.result["timeBreakdownVersion"]?.stringValue {
            timeBreakdownVersion = version
        }
        if pages.keptTooOld {
            dropKept()
            return true
        }
        if pages.holeTooWide {
            // The turns held before the hole go before the newest page draws, never a read of the
            // hole drawn page by page above the newest turn (`bridgeMaxSeqs`).
            dropKept()
            guard !pages.page.isEmpty else { return true }
            // The page is the newest records from a prompt, with older ones on the Mac: it opens
            // the chat as a first attach's page does, and scrolling up reads what is before it.
            var opened = pages
            opened.holeTooWide = false
            opened.gap = nil
            opened.earlier = true
            return caughtUp(opened, CatchUpRead(sessionID: sessionID, after: 0), generation)
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
        // Its history is here: a later load of it reads "Loading chat…", not "Starting…".
        hub?.forgetStartedHere(sessionID)
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

    /// The gap being filled, until all of it is in. It outlives a link drop: the next attach
    /// that catches up reads it whole again, from `cursor` (its start: nothing of it goes in
    /// before all of it is read).
    private(set) var gapFill: GapFill?
    /// The reads filling it, after the newest records showed; cancelled when the link drops
    /// or another attach starts.
    private var gapTask: Task<Void, Never>?
    /// Each gap page's byte cap, as an older page's.
    static let gapBytes = olderBytes

    /// Reads the whole gap oldest first, in bounded pages, while live records go on arriving
    /// (they are newer than anything in it), then sends it to the chat once (`applyGap`): the
    /// turns above the newest one change one time, not once a page. The gap is at most
    /// ``bridgeMaxSeqs`` wide (a wider one opens no gap: `holeTooWide`), so this is a few reads
    /// at most. A page that fails stops the fill with nothing of it shown; the next attach that
    /// catches up (the link back, a lag) reads it again from its start.
    private func startGapFill() {
        guard gapTask == nil, let fill = gapFill, attached, let hub, hub.isReady else { return }
        let generation = generation
        let sessionID = sessionID
        // The task holds the source only between its requests, never across one.
        gapTask = Task { [weak self] in
            var cursor = fill.cursor
            var gapRecords: [JSONValue] = []
            while self?.gapFill == fill, self?.generation == generation, !Task.isCancelled {
                let page: JSONValue
                do {
                    page = try await hub.request("_acpmux/events", .object([
                        "sessionId": .string(sessionID), "afterSeq": .number(Double(cursor)),
                        "limit": .number(Double(Self.pageSize)), "maxBytes": .number(Double(Self.gapBytes)),
                        "toolOutputMaxBytes": .number(Double(Self.toolOutputMaxBytes)), "kinds": Self.kinds(hub),
                    ]), timeout: Self.pageTimeout)
                } catch {
                    if self?.generation == generation {
                        log.info("gap \(sessionID, privacy: .public) after \(fill.cursor, privacy: .public): page after \(cursor, privacy: .public) failed, waits for the next attach")
                        self?.gapTask = nil
                    }
                    return
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                let part = Self.gapPart(page, after: cursor, end: fill.end)
                gapRecords += part.records
                cursor = part.cursor
                if part.done {
                    self.applyGap(gapRecords, fill)
                    break
                }
            }
            if self?.generation == generation { self?.gapTask = nil }
        }
    }

    /// One gap page's records after `after` and before the gap's `end`, in order, each once; the
    /// last seq they reach; and whether the gap is all read.
    static func gapPart(_ page: JSONValue, after: Int, end: Int) -> (records: [JSONValue], cursor: Int, done: Bool) {
        let events = page["events"]?.arrayValue ?? []
        var cursor = after
        var done = events.isEmpty || page["hasMore"] != .bool(true)
        var records: [JSONValue] = []
        for record in events {
            guard let number = record["seq"]?.numberValue else { continue }
            let seq = Int(number)
            if seq >= end {
                done = true
                break
            }
            guard seq > cursor else { continue }
            records.append(record)
            cursor = seq
        }
        // A page that moves nothing on while promising more would be read forever.
        if !done, cursor == after { done = true }
        return (records, cursor, done)
    }

    /// Sends the whole gap to the chat as one page: its records before the gap's end, in
    /// order, each once.
    private func applyGap(_ gapRecords: [JSONValue], _ fill: GapFill) {
        guard gapFill == fill else { return }
        gapFill = nil
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
        log.info("gap \(self.sessionID, privacy: .public) after \(fill.cursor, privacy: .public): \(gapRecords.count, privacy: .public) records, through \(gapRecords.last?["seq"]?.numberValue ?? 0, privacy: .public)")
        // A later reader of this source gets the gap's records where they belong: where the
        // marker was, which goes now that the gap is filled.
        flushOpenChunk()
        if let marker = replay.lastIndex(where: { if case .gapOpened = $0 { true } else { false } }) {
            replay.insert(contentsOf: mapped, at: marker)
            replay.remove(at: marker + mapped.count)
        }
        for continuation in continuations.values { continuation.yield(.gapPage(mapped, done: true)) }
    }

    /// Applies what a catch-up read as one batch. False when a request failed: a reattach
    /// applies what it read up to its last record (no gap: pages are read oldest first from
    /// `lastSeq`), and the rest waits for the retry.
    private func apply(_ pages: CatchUpPages, _ read: CatchUpRead) -> Bool {
        let (result, page) = (pages.result, pages.page)
        log.info("attach \(self.sessionID, privacy: .public) after \(read.after, privacy: .public): \(page.count, privacy: .public) records, through \(page.last?["seq"]?.numberValue ?? 0, privacy: .public), held \(self.held.count, privacy: .public), failed \(pages.failure != nil, privacy: .public)")
        if let failure = pages.failure {
            // Said once per run of failures, and never for a link that is coming back (a
            // timeout, a dropped channel): the kept rows stay and the retry catches up quietly.
            if failures == 0, !Self.isTransient(failure) { emit(.clientError(Self.message(failure))) }
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
            if let name = session.shownName { summary.name = name }
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
            heldEarlier = nil
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

    /// Older records are read before this seq: the oldest record read (the oldest prompt shown,
    /// or the oldest record of the turn above it, kept in `earlierCarry`); nil when the chat
    /// shows its start (or has not opened).
    private var earlierBefore: Int?
    /// Records read before the oldest prompt shown (the end of the turn above it): they go in
    /// with the page that reaches their prompt, and are not read again.
    private var earlierCarry: [JSONValue] = []
    /// The older read on the wire, from this `before` (nil: none).
    private var readingEarlier: Int?
    /// The chat asked for an older page and has none yet: the read on the wire shows when it lands.
    private var earlierWanted = false
    /// The next older page, read and decoded ahead while the chat shows the one after it
    /// (one page at most: the records back to the next prompt, in `olderBytes` reads).
    private var heldEarlier: AcpmuxEarlierPage?
    /// The older read on the wire (`readingEarlier`'s): cancelled when no chat reads this source
    /// any more (``readerLeft()``), when it drops its kept copy, and when it goes away.
    private var earlierTask: Task<Void, Never>?
    /// Older reads that failed in a row (a refused, timed-out or non-advancing page): the next
    /// read waits ``retryDelay(afterFailures:)`` after the last, 250 ms doubling to 15 s, so a
    /// reader near the top of a chat whose reads fail does not send one per scroll step.
    private var earlierFailures = 0
    /// No older read starts before this (the last failure plus its delay).
    private var earlierRetryAt: ContinuousClock.Instant?
    /// The read an ask during the delay waits for: it starts when the delay ends.
    private var earlierRetryTask: Task<Void, Never>?

    /// Nothing waits for older history any more: the read on the wire stops (its requests are
    /// cancelled) and the page held ahead goes. The next ask reads again.
    private func stopEarlier() {
        earlierTask?.cancel()
        earlierTask = nil
        earlierRetryTask?.cancel()
        earlierRetryTask = nil
        earlierFailures = 0
        earlierRetryAt = nil
        readingEarlier = nil
        earlierWanted = false
        heldEarlier = nil
    }

    /// An ask while the last failure's delay runs: the read starts when it ends (the chat's
    /// loading state stays on until then, so its scroll steps ask nothing more).
    private func retryEarlierLater(at instant: ContinuousClock.Instant) {
        guard earlierRetryTask == nil else { return }
        earlierRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.earlierRetryTask = nil
            guard self.earlierWanted else { return }
            self.loadEarlierHistory()
        }
    }

    /// The chat scrolled near its oldest turn: the page before it. One read ahead already is
    /// shown at once; one on the wire shows when it lands. After each page the next is read
    /// ahead, decoded off the main actor and held, so a reader flinging up never waits for one.
    public func loadEarlierHistory() {
        if let hub {
            hub.loadEarlierHistory(sessionID: sessionID)
        } else {
            loadEarlierHistoryDirect()
        }
    }

    /// Fan-out calls from the hub bypass the generation fan-out to avoid recursion.
    fileprivate func loadEarlierHistoryPage() { loadEarlierHistoryDirect() }

    private func loadEarlierHistoryDirect() {

        if let held = heldEarlier {
            heldEarlier = nil
            if held.before == earlierBefore {
                showEarlier(held)
                return
            }
        }
        earlierWanted = true
        guard readingEarlier == nil else { return }
        if let at = earlierRetryAt, ContinuousClock.now < at, earlierBefore != nil {
            retryEarlierLater(at: at)
            return
        }
        guard let before = earlierBefore, let hub, hub.isReady else {
            // Nothing to read now (the start is shown, or the link is down): the chat's
            // loading state ends, so the next scroll up asks again.
            earlierWanted = false
            yieldEarlier([], hasEarlier: earlierBefore != nil)
            return
        }
        readEarlier(before, hub: hub)
    }

    private func readEarlier(_ before: Int, hub: AcpmuxHub) {
        readingEarlier = before
        let sessionID = sessionID
        let mapper = records
        let carry = earlierCarry
        earlierTask = Task { [weak self] in
            let page = await Self.fetchEarlier(hub, sessionID: sessionID, before: before, carry: carry, mapper: mapper)
            // Cancelled (`stopEarlier`): another read may be on the wire by now, and this one's
            // failure is not the chat's.
            guard !Task.isCancelled else { return }
            self?.landEarlier(page)
        }
    }

    /// Reads byte-capped pages before `before` until one holds a prompt or the log starts.
    /// Each read's records map to chat events off the main actor while the next read is on the
    /// wire, and only those the page shows: the records of the last read before its prompt are
    /// the turn above it, carried raw to the next page. `carry` (the last page's) maps at once,
    /// while the first read is on the wire, and goes in at the end.
    private static func fetchEarlier(_ hub: AcpmuxHub, sessionID: String, before: Int,
                                     carry: [JSONValue], mapper: AcpmuxRecords) async -> AcpmuxEarlierPage {
        var page = AcpmuxEarlierPage(before: before)
        let carried = Task.detached(priority: .userInitiated) { carry.flatMap(mapper.map) }
        var cursor = before
        /// Each read's events on their way, newest read first.
        var reads: [Task<[AgentSessionEvent], Never>] = []
        do {
            while true {
                let reply = try await hub.request("_acpmux/events", .object([
                    "sessionId": .string(sessionID), "beforeSeq": .number(Double(cursor)),
                    "limit": .number(Double(pageSize)), "maxBytes": .number(Double(olderBytes)),
                    "toolOutputMaxBytes": .number(Double(toolOutputMaxBytes)), "kinds": kinds(hub),
                ]), timeout: pageTimeout)
                var events = reply["events"]?.arrayValue ?? []
                let hasMore = reply["hasMore"] == .bool(true)
                // hasMore means the server promises older records. An empty or
                // non-advancing page is a failed read, never the start of history:
                // dropping earlierBefore here permanently hides older turns.
                if hasMore {
                    guard let oldest = events.first?["seq"]?.numberValue,
                          oldest.isFinite, oldest >= 0, oldest < Double(cursor) else {
                        page.failed = true
                        break
                    }
                }
                let more = !events.isEmpty && hasMore
                let prompt = more ? events.firstIndex(where: isPrompt) : nil
                if let prompt {
                    // The page starts at its oldest prompt; what is before it is the turn above.
                    page.carry = Array(events[..<prompt])
                    page.nextBefore = (events.first?["seq"]?.numberValue).map { Int($0) }
                    events = Array(events[prompt...])
                }
                page.records += events.count
                let shown = events
                reads.append(Task.detached(priority: .userInitiated) { shown.flatMap(mapper.map) })
                guard more, prompt == nil, let oldest = events.first?["seq"]?.numberValue else { break }
                cursor = Int(oldest)
            }
        } catch {
            page.failed = true
        }
        guard !page.failed else {
            for read in reads { read.cancel() }
            carried.cancel()
            page.carry = []
            return page
        }
        for read in reads.reversed() { page.events += await read.value }
        page.events += await carried.value
        page.records += carry.count
        return page
    }

    private func landEarlier(_ page: AcpmuxEarlierPage) {
        readingEarlier = nil
        earlierTask = nil
        if page.failed {
            earlierFailures += 1
            earlierRetryAt = ContinuousClock.now + Self.retryDelay(afterFailures: earlierFailures)
        } else {
            earlierFailures = 0
            earlierRetryAt = nil
        }
        guard earlierBefore == page.before else {
            // The chat opened again since (a first attach, kept records restored): a reader
            // still waiting gets the page before what it shows now.
            if earlierWanted {
                earlierWanted = false
                loadEarlierHistory()
            }
            return
        }
        if earlierWanted {
            earlierWanted = false
            showEarlier(page)
        } else if !page.failed {
            heldEarlier = page
        }
    }

    /// Puts an older page in front of the chat as whole turns, and reads the next one ahead.
    private func showEarlier(_ page: AcpmuxEarlierPage) {
        guard !page.failed else {
            // Nothing applied: the next scroll up reads the same page again, once the failure's
            // delay has passed (`earlierRetryAt`).
            log.info("earlier \(self.sessionID, privacy: .public) before \(page.before, privacy: .public): failed \(self.earlierFailures, privacy: .public) in a row")
            yieldEarlier([], hasEarlier: earlierBefore != nil)
            return
        }
        earlierBefore = page.nextBefore
        earlierCarry = page.carry
        let hasEarlier = earlierBefore != nil
        log.info("earlier \(self.sessionID, privacy: .public) before \(page.before, privacy: .public): \(page.records, privacy: .public) records, \(page.carry.count, privacy: .public) carried, more \(hasEarlier, privacy: .public)")
        // A new reader of this source gets the older turns first, then the rest, in order.
        flushOpenChunk()
        if !page.events.isEmpty { replay.prepend(page.events) }
        yieldEarlier(page.events, hasEarlier: hasEarlier)
        // One page ahead: read and decode while the reader scrolls toward it.
        if let next = earlierBefore, readingEarlier == nil, let hub, hub.isReady { readEarlier(next, hub: hub) }
    }

    private func yieldEarlier(_ events: [AgentSessionEvent], hasEarlier: Bool) {
        flushOpenChunk()
        replay.append([.earlierHistory(hasEarlier)])
        for continuation in continuations.values { continuation.yield(.earlierPage(events, hasEarlier: hasEarlier)) }
    }

    func receive(record: JSONValue) {
        guard attached else {
            // Only while an attach runs: its pages may end before them. With no attach
            // running, the next one reads from `lastSeq` to the log's end, these included.
            if attaching || pipelined != nil { held.append(record) }
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
        for continuation in continuations.values { continuation.yield(.batch(events)) }
    }

    private func emitLocal(_ event: AgentSessionEvent) {
        if let hub { hub.emitLocal(event, sessionID: sessionID) }
        else { emit(event) }
    }

    fileprivate func receiveLocal(_ event: AgentSessionEvent) { emit(event) }

    /// The turn the Mac is running, as the events say: a Stop pressed for it is tied to it.
    private(set) var runningTurnID: String?

    private func trackRunningTurn(_ event: AgentSessionEvent) {
        switch event {
        case .turnStarted(let turnID, _): runningTurnID = turnID
        case .turnResult(let turnID, _, _, _): if runningTurnID == turnID { runningTurnID = nil }
        case .batch(let events): for inner in events { trackRunningTurn(inner) }
        default: break
        }
    }

    /// Whether a Stop pressed while `pressedFor` ran still applies to what runs now: not when that
    /// turn ended and another started while the call waited for the link. Unknown (nil) goes.
    nonisolated static func stopStillApplies(pressedFor: String?, running: String?) -> Bool {
        guard let pressedFor else { return true }
        return running == pressedFor
    }

    private func emit(_ event: AgentSessionEvent) {
        trackRunningTurn(event)
        switch event {
        case .clientError, .promptNotSent, .pendingSends, .historyLoading:
            // Not history: a later reader learns the load state from `events()` itself.
            break
        default:
            if history != nil {
                history?.append(event)
                return
            }
            record(replay: event)
        }
        for continuation in continuations.values { continuation.yield(event) }
    }

    /// Keeps `event` for a later reader while bounding the replay. Consecutive
    /// streamed chunks are joined so the cache grows with messages, not tokens.
    private func record(replay event: AgentSessionEvent) {
        guard !replay.requiresResync else { return }
        let textBytes: Int
        switch event {
        case .update(.agentMessageChunk(let text, _)), .update(.agentThoughtChunk(let text)):
            textBytes = text.utf8.count
        default:
            textBytes = 0
        }
        // Coalescing must not hide an indefinitely growing reply from the event
        // budget. Bound each joined chunk to the same byte budget as an open.
        guard textBytes <= Self.openBytes else {
            replay.invalidate()
            openChunk = nil
            openChunkText = ""
            openChunkBytes = 0
            return
        }
        if textBytes > Self.openBytes - openChunkBytes { flushOpenChunk() }
        guard !replay.requiresResync else { return }
        switch (openChunk, event) {
        case (.message(let id)?, .update(.agentMessageChunk(let text, let nextID))) where id == nextID:
            openChunkText += text
            openChunkBytes += textBytes
        case (.thought?, .update(.agentThoughtChunk(let text))):
            openChunkText += text
            openChunkBytes += textBytes
        default:
            flushOpenChunk()
            guard !replay.requiresResync else { return }
            switch event {
            case .update(.agentMessageChunk(let text, let id)):
                openChunk = .message(id)
                openChunkText = text
                openChunkBytes = textBytes
            case .update(.agentThoughtChunk(let text)):
                openChunk = .thought
                openChunkText = text
                openChunkBytes = textBytes
            default:
                replay.append([event])
            }
        }
    }

    private enum OpenChunk { case message(String?), thought }
    private var openChunk: OpenChunk?
    private var openChunkText = ""
    private var openChunkBytes = 0

    private func flushOpenChunk() {
        guard let chunk = openChunk else { return }
        switch chunk {
        case .message(let id): replay.append([.update(.agentMessageChunk(text: openChunkText, messageId: id))])
        case .thought: replay.append([.update(.agentThoughtChunk(text: openChunkText))])
        }
        openChunk = nil
        openChunkText = ""
        openChunkBytes = 0
    }

    /// How many events the source keeps for a later reader (tests).
    var replayCount: Int { replay.events.count + (openChunk == nil ? 0 : 1) }
    /// An older read is on the wire or waits for its retry (tests).
    var isReadingEarlier: Bool { readingEarlier != nil || earlierRetryTask != nil }
}

// MARK: - Older history pages (AcpmuxSessionSource.loadEarlierHistory)

/// An older page: the records from the oldest prompt read on, as chat events, and where the
/// page before it starts. `before` is the `earlierBefore` it was read from: it shows only while
/// that is still the chat's.
struct AcpmuxEarlierPage: Sendable {
    var before: Int
    var events: [AgentSessionEvent] = []
    /// The records read past the page's prompt (the turn above it): the next page's start.
    var carry: [JSONValue] = []
    /// Where the page before this one is read from (nil: this page reaches the chat's start).
    var nextBefore: Int?
    var records = 0
    /// A read failed: nothing shows, and the next ask reads the same page again.
    var failed = false
}

// MARK: - One-request catch-up (`catch-up` link service)

extension AcpmuxHub {
    /// The open chats and the last event each holds, for a `catch-up` request (each once).
    func catchUpChats() -> [(sessionID: String, lastSeq: Int)] {
        var seen = Set<String>()
        return liveSources.compactMap { source in
            seen.insert(source.sessionID).inserted ? (source.sessionID, source.heldSeq) : nil
        }
    }
}

extension AcpmuxSessionSource {
    /// The last record applied (`lastSeq`).
    var heldSeq: Int { lastSeq }
}
