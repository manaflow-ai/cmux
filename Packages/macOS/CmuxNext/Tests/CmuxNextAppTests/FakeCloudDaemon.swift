import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
@testable import CmuxNextApp

/// A fake daemon cloud proxy (`cloud-conversations-v1`): canned owner
/// answers and a log of every command, for `CloudHomeSource` tests. It
/// holds a lease like the daemon: the account a token names (its `sub`).
nonisolated final class FakeCloudDaemon: CloudConversationCommands, CloudLeaseSessions {
    enum Call: Hashable {
        case inboxList
        case snapshot(String, tail: Int)
        case history(String, before: UInt64, limit: Int)
        case op(conversation: String?, key: String, kind: String)
        case subscribeInbox
        case subscribe(String)
        case unsubscribe(String)
        case setSession(String?)
        case clearSession
    }

    /// An op as the daemon sent it: its key and the account of the lease it carried.
    struct SentOp: Hashable {
        var key: String
        var subject: String?
    }

    struct Script {
        var entries: [CloudInboxEntry] = []
        var heads: [String: CmuxNextDaemon.ConversationSummary] = [:]
        var messages: [String: [ConversationMessage]] = [:]
        /// The subscribe reply's state: the shared socket's true state.
        var subscribeState = "live"
        /// The subscribe reply's `account` (the lease's `sub`), when set.
        var subscribeAccount: String?
        /// Answers ops by kind; default: a committed op at rev 2.
        var op: @Sendable (CloudConversationOpRequest) throws -> CloudConversationOpResult = { _ in CloudConversationOpResult(rev: 2) }
        var inboxError: DaemonError?
        /// Holds every snapshot reply until the test opens it.
        var snapshotGate: Gate?
        /// Holds every history reply until the test opens it.
        var historyGate: Gate?
        /// Holds every unsubscribe until the test opens it; it takes effect after.
        var unsubscribeGate: Gate?
        /// When set, the inbox is the leased account's, and listing without a
        /// lease is refused (`cloud_signed_out`).
        var inboxBySubject: [String: [CloudInboxEntry]]?
        /// Holds every inbox list reply until the test opens it.
        var inboxGate: Gate?
        /// The inbox list's revision (UserDO's inbox stream seq).
        var revision: JSONValue?
    }

    private struct Daemon {
        var session: String?
        /// The `expires_at` of the lease set last.
        var expiry: UInt64?
        var sent: [SentOp] = []
        var subscribed: Set<String> = []
        var snapshotsInFlight = 0
        var maxSnapshotsInFlight = 0
    }

    let script: Mutex<Script>
    private let log = Mutex<[Call]>([])
    private let requests = Mutex<[CloudConversationOpRequest]>([])
    private let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let daemon = Mutex(Daemon())

    init(_ script: Script = Script()) {
        self.script = Mutex(script)
    }

    var calls: [Call] { log.withLock { $0 } }
    var opRequests: [CloudConversationOpRequest] { requests.withLock { $0 } }
    var ops: [Call] { calls.filter { if case .op = $0 { true } else { false } } }
    var sentOps: [SentOp] { daemon.withLock { $0.sent } }
    /// The `expires_at` of the lease set last (what `cloud-session-needed` names).
    var leaseExpiry: UInt64? { daemon.withLock { $0.expiry } }
    /// The number of leases set so far.
    var leases: Int { calls.filter { if case .setSession = $0 { true } else { false } }.count }
    /// Conversations the daemon streams to this client now.
    var subscribed: Set<String> { daemon.withLock { $0.subscribed } }
    var maxSnapshotsInFlight: Int { daemon.withLock { $0.maxSnapshotsInFlight } }

    private func record(_ call: Call) {
        // The log lock is held while the waiters drain, so a waiter cannot miss a call.
        let woken = log.withLock { log in
            log.append(call)
            return waiters.withLock { waiters in defer { waiters = [] }; return waiters }
        }
        for waiter in woken { waiter.resume() }
    }

    /// Waits until `condition` holds over the calls; each call wakes it.
    /// The suite's time limit bounds a condition that never holds.
    func wait(_ condition: @escaping @Sendable ([Call]) -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition(calls) { return true }
            if Task.isCancelled { break }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    log.withLock { log in
                        if condition(log) || Task.isCancelled {
                            continuation.resume()
                        } else {
                            waiters.withLock { $0.append(continuation) }
                        }
                    }
                }
            } onCancel: {
                // The time limit cancels the test: wake the waiter so it fails instead of hanging the run.
                let woken = log.withLock { _ in waiters.withLock { waiters in defer { waiters = [] }; return waiters } }
                for waiter in woken { waiter.resume() }
            }
        }
        return condition(calls)
    }

    func inboxList(limit: Int) async throws -> CloudInboxList {
        record(.inboxList)
        if let gate = script.withLock({ $0.inboxGate }) { await gate.pass() }
        let (entries, error, bySubject, revision) = script.withLock { ($0.entries, $0.inboxError, $0.inboxBySubject, $0.revision) }
        if let error { throw error }
        guard let bySubject else { return CloudInboxList(entries: entries, revision: revision) }
        guard let session = daemon.withLock({ $0.session }) else {
            throw DaemonError.command(cmd: "cloud-inbox-list", message: "signed out", code: "cloud_signed_out",
                                      details: .object(["reason": .string("missing")]), retryable: false)
        }
        return CloudInboxList(entries: bySubject[session] ?? [], revision: revision)
    }

    func snapshot(_ conversation: String, tail: Int) async throws -> CloudConversationSnapshot {
        record(.snapshot(conversation, tail: CloudConversationSnapshotRequest(conversation: conversation, tail: tail).tail))
        daemon.withLock { daemon in
            daemon.snapshotsInFlight += 1
            daemon.maxSnapshotsInFlight = max(daemon.maxSnapshotsInFlight, daemon.snapshotsInFlight)
        }
        defer { daemon.withLock { $0.snapshotsInFlight -= 1 } }
        if let gate = script.withLock({ $0.snapshotGate }) { await gate.pass() }
        let (head, messages) = script.withLock { ($0.heads[conversation], $0.messages[conversation] ?? []) }
        guard let head else {
            throw DaemonError.command(cmd: "cloud-conversation-snapshot", message: "unknown", code: "cloud_conversation_rejected",
                                      details: .object(["reason": .string("unknown_conversation")]), retryable: false)
        }
        return CloudConversationSnapshot(conversation: head, messages: Array(messages.suffix(tail)), rev: head.rev, seq: 1)
    }

    func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> CloudConversationHistory {
        record(.history(conversation, before: seq, limit: limit))
        if let gate = script.withLock({ $0.historyGate }) { await gate.pass() }
        let older = script.withLock { ($0.messages[conversation] ?? []).filter { $0.seq < seq } }
        return CloudConversationHistory(messages: Array(older.suffix(limit)), hasMore: older.count > limit)
    }

    func op(_ request: CloudConversationOpRequest) async throws -> CloudConversationOpResult {
        requests.withLock { $0.append(request) }
        daemon.withLock { $0.sent.append(SentOp(key: request.idempotencyKey, subject: $0.session)) }
        record(.op(conversation: request.conversation, key: request.idempotencyKey, kind: request.op.kindName))
        let answer = script.withLock { $0.op }
        return try answer(request)
    }

    func subscribeInbox() async throws -> CloudSubscription {
        record(.subscribeInbox)
        return CloudSubscription(state: "connecting")
    }

    func subscribe(_ conversation: String) async throws -> CloudSubscription {
        record(.subscribe(conversation))
        daemon.withLock { _ = $0.subscribed.insert(conversation) }
        let (state, account) = script.withLock { ($0.subscribeState, $0.subscribeAccount) }
        let accountField = account.map { #","account":"\#($0)""# } ?? ""
        let reply = #"{"conversation":"\#(conversation)","state":"\#(state)"\#(accountField)}"#
        return try JSONDecoder().decode(CloudSubscription.self, from: Data(reply.utf8))
    }

    func unsubscribe(_ conversation: String) async throws {
        if let gate = script.withLock({ $0.unsubscribeGate }) { await gate.pass() }
        daemon.withLock { _ = $0.subscribed.remove(conversation) }
        record(.unsubscribe(conversation))
    }

    func setSession(_ request: CloudSessionSetRequest) async throws -> CloudSessionState {
        let subject = CloudFixtures.subject(ofJWT: request.accessToken)
        daemon.withLock { daemon in
            daemon.session = subject
            daemon.expiry = request.expiresAt
        }
        record(.setSession(subject))
        return CloudSessionState(state: "active", apiBaseURL: request.apiBaseURL, expiresAt: request.expiresAt)
    }

    func clearSession() async throws -> CloudSessionState {
        daemon.withLock { $0.session = nil }
        record(.clearSession)
        return CloudSessionState(state: "signed_out")
    }
}

/// The signed-in account as the lease sees it: a JWT whose `sub` is the
/// current user, or a failure while that user's token cannot be read.
final class FakeTokens: CloudLeaseTokens {
    var user: String?
    var failing: Set<String> = []
    /// Holds every token read until the test opens it; the token names the
    /// user signed in when it passes.
    var gate: Gate?
    /// Tokens carry no `sub` claim.
    var withoutSubject = false
    /// Each token expires one second after the one before, as a refreshed
    /// token does, so a lease's `expires_at` names it.
    private var issued: Int = 0

    var isSignedIn: Bool { user != nil }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if let gate { await gate.pass() }
        guard let user, !failing.contains(user) else { throw URLError(.notConnectedToInternet) }
        issued += 1
        let exp = Int(Date().timeIntervalSince1970) + 3600 + issued
        return withoutSubject ? CloudFixtures.jwt(claims: #"{"exp":4102444800}"#) : CloudFixtures.jwt(claims: #"{"sub":"\#(user)","exp":\#(exp)}"#)
    }
}

/// A reply the test holds: the daemon waits in `pass()` until `open()`,
/// and the test waits in `arrived()` until the daemon is there.
nonisolated final class Gate: Sendable {
    private struct State {
        var arrived = false
        var open = false
        var arrivals: [CheckedContinuation<Void, Never>] = []
        var passers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func pass() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.arrived = true
                for arrival in state.arrivals { arrival.resume() }
                state.arrivals = []
                if state.open { continuation.resume() } else { state.passers.append(continuation) }
            }
        }
    }

    func arrived() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.arrived { continuation.resume() } else { state.arrivals.append(continuation) }
            }
        }
    }

    func open() {
        state.withLock { state in
            state.open = true
            for passer in state.passers { passer.resume() }
            state.passers = []
        }
    }
}

/// Fixtures shared by the cloud Home tests.
nonisolated enum CloudFixtures {
    static let at = "2026-10-03T12:00:00.000Z"
    static let localMe = ParticipantID("user_local")
    static let identity = CloudIdentity(stackUserID: "stack-me", displayName: "Me", localID: localMe)

    static func participant(_ id: String, _ name: String, kind: ConversationParticipant.Kind = .human) -> ConversationParticipant {
        ConversationParticipant(id: id, kind: kind, displayName: name)
    }

    static func message(_ conversation: String, seq: UInt64, author: String = "user_bob", text: String = "hi",
                        client: String? = nil) -> ConversationMessage {
        ConversationMessage(id: "msg_\(conversation)_\(seq)", conversation: conversation, seq: seq, clientMsgID: client ?? "c\(seq)",
                            author: author, parts: [.text(text, runs: [])], createdAt: at)
    }

    static func head(_ id: String, rev: UInt64 = 3, lastSeq: UInt64 = 1, kind: String = "dm",
                     participants: [ConversationParticipant] = [participant("user_stack-me", "Me"), participant("user_bob", "Bob")],
                     cursors: [String: UInt64] = ["user_stack-me": 1]) -> CmuxNextDaemon.ConversationSummary {
        CmuxNextDaemon.ConversationSummary(id: id, owner: "cloud", title: "", participants: participants, lastSeq: lastSeq, rev: rev,
                                           createdAt: at, updatedAt: at, lastMessage: lastSeq > 0 ? message(id, seq: lastSeq) : nil,
                                           readCursors: cursors, kind: kind)
    }

    /// An unsigned JWT for `sub` that expires in an hour.
    static func jwt(sub: String) -> String {
        let exp = Int(Date().timeIntervalSince1970) + 3600
        return jwt(claims: #"{"sub":"\#(sub)","exp":\#(exp)}"#)
    }

    /// An unsigned JWT with these claims.
    static func jwt(claims: String) -> String {
        let body = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
    }

    /// The `sub` of a token `jwt(sub:)` made.
    static func subject(ofJWT token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["sub"] as? String
    }

    static func unavailable() -> DaemonError {
        .command(cmd: "cloud-conversation-op", message: "unavailable", code: "cloud_unavailable",
                 details: .object(["reason": .string("unavailable")]), retryable: true)
    }

    static func entry(_ id: String, rev: UInt64 = 3, lastSeq: UInt64 = 1, pinned: Bool = false, peer: String? = "user_bob",
                      archived: Bool = false) -> CloudInboxEntry {
        CloudInboxEntry(conversation: id, rev: rev, kind: "dm", lastSeq: lastSeq, lastAt: at, preview: "Bob: hi", dmPeer: peer,
                        pinned: pinned, pinPosition: pinned ? 0 : nil, archived: archived)
    }
}

/// Collects a source's events and waits for them without a clock: each
/// event wakes the waiters, which check their condition again.
nonisolated final class EventTape: Sendable {
    private struct State {
        var events: [HomeEvent] = []
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = Mutex(State())
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ source: any HomeSource) async {
        let stream = await source.events()
        task.withLock {
            $0 = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    let waiters = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
                        state.events.append(event)
                        defer { state.waiters = [] }
                        return state.waiters
                    }
                    for waiter in waiters { waiter.resume(returning: false) }
                }
            }
        }
    }

    deinit { task.withLock { $0?.cancel() } }

    var all: [HomeEvent] { state.withLock { $0.events } }

    /// Waits until `condition` holds over the events. The suite's time limit
    /// bounds a condition that never holds; so does a cap on wake-ups.
    func wait(_ condition: @Sendable ([HomeEvent]) -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if Task.isCancelled { break }
            let done = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    state.withLock { state in
                        if condition(state.events) {
                            continuation.resume(returning: true)
                        } else if Task.isCancelled {
                            continuation.resume(returning: false)
                        } else {
                            state.waiters.append(continuation)
                        }
                    }
                }
            } onCancel: {
                // The time limit cancels the test: wake the waiter so it fails instead of hanging the run.
                let waiters = state.withLock { state in
                    defer { state.waiters = [] }
                    return state.waiters
                }
                for waiter in waiters { waiter.resume(returning: false) }
            }
            if done { return true }
        }
        return condition(all)
    }
}
