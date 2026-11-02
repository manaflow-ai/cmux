// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

private let approvalLogger = Logger(subsystem: "com.cmuxterm.cua", category: "approval")

/// Asks the person, through the host, before an agent session uses an app
/// outside its manifest (docs/computer-use-approvals.md, "The approval
/// question"), and keeps what they allowed: each session's grants, one-call
/// credits from a late "once", and the cmux client's saved list.
///
/// Wire on the host consent link (`HostConsentServer`), JSON lines:
///   worker -> host: {"type":"app_approval","id":N,"request":{...,"digest":D}}
///   host -> worker: {"type":"app_approval","id":N,"ok":true,"decision":"once"|"session"|"always"|"deny","digest":D,"via":S}
///                   {"type":"app_approval","id":N,"ok":false}
///   worker -> host: {"type":"app_approval_cancel","id":N}           (the session ended)
///   host -> worker: {"type":"approved_apps","apps":[{"bundle_id"|"executable","name"}]}
///                   {"type":"revoke","scope":"all"|"app","app":{...}}
///
/// Rules:
/// - A call waits until `wait_until_ms` (2 minutes), then fails with
///   `approval_timeout`; the question stays answerable until
///   `answerable_until_ms` (10 minutes). A late "session" or "always"
///   grants the app; a late "once" leaves one call's credit, so the retry runs.
/// - One question per session x app: parallel calls join it. "once" runs one
///   of them (the asker, or the earliest still waiting); the others ask again.
/// - A decision with another digest, a second answer, an answer after
///   `answerable_until_ms` or on another link is ignored. `ok:false`, a lost
///   link, or no link at all fails the waiting calls closed.
/// - Only the attached host link answers; nothing on an agent's socket does.
public final class AppApprovalBroker: Sendable {
    /// What a waiting call gets back.
    enum Outcome: Sendable, Equatable {
        case decided(AppApprovalDecision)
        /// Another joined call used the "once"; ask again.
        case retry
        case timeout
        case unavailable
        /// The session closed while it waited.
        case ended
    }

    /// Whether a session may use an app now.
    enum Allowance: Sendable, Equatable {
        case granted
        /// A late "once" credit, now spent on this call.
        case once
        case none
    }

    public struct Timing: Sendable {
        public var wait: Duration
        public var answerable: Duration

        public init(wait: Duration = .seconds(120), answerable: Duration = .seconds(600)) {
            self.wait = wait
            self.answerable = answerable
        }
    }

    /// Unix milliseconds now.
    public typealias Now = @Sendable () -> Int64
    /// Runs the closure after the delay (a bounded deadline, never a wait for a state).
    public typealias Schedule = @Sendable (Duration, @escaping @Sendable () -> Void) -> Void

    struct Question {
        let request: AppApprovalRequest
        let link: UInt64
        let app: ApprovalApp
        /// The asking call's waiter.
        let asker: UInt64
        var waiters: [UInt64: CheckedContinuation<Outcome, Never>] = [:]
    }

    struct Session {
        var labels: SessionLabels
        var grants: [String: ApprovalApp] = [:]
        var credits: [String: ApprovalApp] = [:]
    }

    struct State {
        var link: (id: UInt64, send: @Sendable (Data) -> Void)?
        var nextLink: UInt64 = 1
        var nextQuestion = 1
        var nextWaiter: UInt64 = 1
        var sessions: [String: Session] = [:]
        var saved: [String: ApprovalApp] = [:]
        var questions: [Int: Question] = [:]
        /// "session\napp key" -> question id.
        var open: [String: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let client: String
    private let machine: String
    private let timing: Timing
    private let now: Now
    private let schedule: Schedule

    public init(client: String, machine: String, timing: Timing = Timing(),
                now: @escaping Now = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
                schedule: @escaping Schedule = { delay, action in
                    // task-owner: one bounded deadline per question or waiter; the action is a no-op once answered.
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(for: delay)
                        action()
                    }
                }) {
        self.client = client
        self.machine = machine
        self.timing = timing
        self.now = now
        self.schedule = schedule
    }

    // MARK: Host link

    /// A verified host connection becomes the one that answers; questions
    /// asked on an earlier one fail closed. Returns the link id.
    func attach(_ send: @escaping @Sendable (Data) -> Void) -> UInt64 {
        let (link, dropped) = state.withLockUnchecked { state -> (UInt64, [CheckedContinuation<Outcome, Never>]) in
            let link = state.nextLink
            state.nextLink += 1
            state.link = (link, send)
            return (link, Self.dropQuestions(&state) { $0.link != link })
        }
        for waiter in dropped { waiter.resume(returning: .unavailable) }
        return link
    }

    /// The host connection closed: its questions fail closed.
    func detach(_ link: UInt64) {
        let dropped = state.withLockUnchecked { state -> [CheckedContinuation<Outcome, Never>] in
            if state.link?.id == link { state.link = nil }
            return Self.dropQuestions(&state) { $0.link == link }
        }
        for waiter in dropped { waiter.resume(returning: .unavailable) }
    }

    /// One line from the host link. Returns false when it is not an approval line.
    @discardableResult
    func receive(_ message: [String: Any], link: UInt64) -> Bool {
        switch message["type"] as? String {
        case "app_approval":
            guard let id = message["id"] as? Int else { return true }
            answer(id: id, ok: message["ok"] as? Bool == true,
                   decision: (message["decision"] as? String).flatMap(AppApprovalDecision.init(rawValue:)),
                   digest: message["digest"] as? String, link: link)
        case "approved_apps":
            guard let apps = message["apps"] as? [[String: Any]] else { return true }
            replaceSaved(apps.compactMap(ApprovalApp.init(wire:)), link: link)
        case "revoke":
            switch message["scope"] as? String {
            case "all": revoke(nil, link: link)
            case "app":
                if let app = (message["app"] as? [String: Any]).flatMap(ApprovalApp.init(wire:)) { revoke(app, link: link) }
            default: break
            }
        default: return false
        }
        return true
    }

    // MARK: Sessions

    func openSession(_ id: String, labels: SessionLabels = SessionLabels()) {
        state.withLockUnchecked { $0.sessions[id] = Session(labels: labels) }
    }

    func label(_ id: String, _ labels: SessionLabels) {
        state.withLockUnchecked { $0.sessions[id]?.labels = labels }
    }

    /// The session closed: its grants go, its open questions are cancelled
    /// on the host, and its waiting calls end.
    func endSession(_ id: String) {
        let (send, cancelled, waiters) = state.withLockUnchecked { state
            -> ((@Sendable (Data) -> Void)?, [Int], [CheckedContinuation<Outcome, Never>]) in
            state.sessions[id] = nil
            let ids = state.questions.filter { $0.value.request.session == id }.map(\.key)
            var waiters: [CheckedContinuation<Outcome, Never>] = []
            for questionID in ids {
                if let question = state.questions.removeValue(forKey: questionID) {
                    state.open[Self.openKey(id, question.app)] = nil
                    waiters += question.waiters.values
                }
            }
            return (state.link?.send, ids.sorted(), waiters)
        }
        for questionID in cancelled { send?(HelperWire.line(["type": "app_approval_cancel", "id": questionID])) }
        for waiter in waiters { waiter.resume(returning: .ended) }
    }

    /// Drops this session's own grants and credits (its lifetime or idle
    /// limit passed); the saved list stays.
    func resetGrants(_ id: String) {
        state.withLockUnchecked { state in
            state.sessions[id]?.grants = [:]
            state.sessions[id]?.credits = [:]
        }
    }

    /// The apps this session's manifest lists: its grants and the saved list.
    func allowedApps(_ id: String) -> [ApprovalApp] {
        state.withLockUnchecked { state in
            guard let session = state.sessions[id] else { return [] }
            return session.grants.merging(state.saved) { granted, _ in granted }.values.sorted { $0.key < $1.key }
        }
    }

    /// Whether `id` may use `app` now; a credit is spent by asking.
    func allowance(_ id: String, _ app: ApprovalApp) -> Allowance {
        state.withLockUnchecked { state in
            guard let session = state.sessions[id] else { return .none }
            if session.grants[app.key] != nil || state.saved[app.key] != nil { return .granted }
            if state.sessions[id]?.credits.removeValue(forKey: app.key) != nil { return .once }
            return .none
        }
    }

    // MARK: Asking

    /// Asks the host whether session `id` may use `app` for `tool`, or joins
    /// the question already open for that session and app.
    func ask(session id: String, app: ApprovalApp, tool: String, risk: String) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let start = now()
            enum Step {
                case fail(Outcome)
                case asked(Data, @Sendable (Data) -> Void, question: Int, waiter: UInt64, wait: Duration)
                case joined(question: Int, waiter: UInt64, wait: Duration)
            }
            let step = state.withLockUnchecked { state -> Step in
                guard let session = state.sessions[id] else { return .fail(.ended) }
                guard let link = state.link else { return .fail(.unavailable) }
                let waiter = state.nextWaiter
                state.nextWaiter += 1
                let openKey = Self.openKey(id, app)
                if let questionID = state.open[openKey], state.questions[questionID] != nil {
                    state.questions[questionID]?.waiters[waiter] = continuation
                    let until = state.questions[questionID]?.request.answerableUntilMs ?? start
                    let wait = min(Self.milliseconds(timing.wait), max(0, until - start))
                    return .joined(question: questionID, waiter: waiter, wait: .milliseconds(wait))
                }
                let request = AppApprovalRequest(
                    nonce: Self.nonce(), client: client, machine: machine, session: id,
                    agent: session.labels.agent, workspace: session.labels.workspace, target: app, tool: tool,
                    risk: risk, createdMs: start, waitUntilMs: start + Self.milliseconds(timing.wait),
                    answerableUntilMs: start + Self.milliseconds(timing.answerable)
                )
                let questionID = state.nextQuestion
                state.nextQuestion += 1
                var question = Question(request: request, link: link.id, app: app, asker: waiter)
                question.waiters[waiter] = continuation
                state.questions[questionID] = question
                state.open[openKey] = questionID
                let line = HelperWire.line(["type": "app_approval", "id": questionID, "request": request.wire])
                return .asked(line, link.send, question: questionID, waiter: waiter, wait: timing.wait)
            }
            switch step {
            case .fail(let outcome):
                continuation.resume(returning: outcome)
            case .asked(let line, let send, let question, let waiter, let wait):
                approvalLogger.notice("asking app approval id=\(question, privacy: .public) tool=\(tool, privacy: .public)")
                schedule(wait) { [weak self] in self?.expire(waiter: waiter, of: question) }
                schedule(timing.answerable) { [weak self] in self?.expire(question: question) }
                send(line)
            case .joined(let question, let waiter, let wait):
                schedule(wait) { [weak self] in self?.expire(waiter: waiter, of: question) }
            }
        }
    }

    /// The question in flight for this session and app, if any (tests and status).
    func openRequest(session id: String, app: ApprovalApp) -> (id: Int, request: AppApprovalRequest)? {
        state.withLockUnchecked { state in
            guard let questionID = state.open[Self.openKey(id, app)],
                  let question = state.questions[questionID] else { return nil }
            return (questionID, question.request)
        }
    }

    private func answer(id: Int, ok: Bool, decision: AppApprovalDecision?, digest: String?, link: UInt64) {
        let current = now()
        let resumes = state.withLockUnchecked { state -> [(CheckedContinuation<Outcome, Never>, Outcome)] in
            guard state.link?.id == link, let question = state.questions[id], question.link == link else { return [] }
            guard current <= question.request.answerableUntilMs else { return [] }
            if !ok {
                Self.remove(id, from: &state)
                return question.waiters.values.map { ($0, Outcome.unavailable) }
            }
            // A wrong digest or an unknown decision is no answer: the question stays open.
            guard let decision, digest == question.request.digest else { return [] }
            Self.remove(id, from: &state)
            let session = question.request.session
            switch decision {
            case .session:
                state.sessions[session]?.grants[question.app.key] = question.app
            case .always:
                state.saved[question.app.key] = question.app
                state.sessions[session]?.grants[question.app.key] = question.app
            case .once:
                let runner: UInt64? = question.waiters[question.asker] != nil
                    ? question.asker : question.waiters.keys.min()
                guard let runner else {
                    // Every call already timed out: the agent's retry gets this one call.
                    state.sessions[session]?.credits[question.app.key] = question.app
                    return []
                }
                return question.waiters.map { ($0.value, $0.key == runner ? Outcome.decided(.once) : Outcome.retry) }
            case .deny:
                break
            }
            return question.waiters.values.map { ($0, Outcome.decided(decision)) }
        }
        for (waiter, outcome) in resumes { waiter.resume(returning: outcome) }
    }

    private func replaceSaved(_ apps: [ApprovalApp], link: UInt64) {
        state.withLockUnchecked { state in
            guard state.link?.id == link else { return }
            state.saved = Dictionary(apps.map { ($0.key, $0) }) { first, _ in first }
        }
    }

    /// `app` nil revokes everything: the saved list, every session's grants and credits.
    private func revoke(_ app: ApprovalApp?, link: UInt64) {
        state.withLockUnchecked { state in
            guard state.link?.id == link else { return }
            if let app {
                state.saved[app.key] = nil
                for id in state.sessions.keys {
                    state.sessions[id]?.grants[app.key] = nil
                    state.sessions[id]?.credits[app.key] = nil
                }
            } else {
                state.saved = [:]
                for id in state.sessions.keys {
                    state.sessions[id]?.grants = [:]
                    state.sessions[id]?.credits = [:]
                }
            }
        }
    }

    /// One call's wait ended; its question stays answerable.
    private func expire(waiter: UInt64, of question: Int) {
        let continuation = state.withLockUnchecked { $0.questions[question]?.waiters.removeValue(forKey: waiter) }
        continuation?.resume(returning: .timeout)
    }

    /// The question is no longer answerable.
    private func expire(question: Int) {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Outcome, Never>] in
            guard let removed = state.questions[question] else { return [] }
            Self.remove(question, from: &state)
            return Array(removed.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: .timeout) }
    }

    private static func remove(_ id: Int, from state: inout State) {
        guard let question = state.questions.removeValue(forKey: id) else { return }
        let key = openKey(question.request.session, question.app)
        if state.open[key] == id { state.open[key] = nil }
    }

    private static func dropQuestions(_ state: inout State, where matches: (Question) -> Bool)
        -> [CheckedContinuation<Outcome, Never>] {
        let ids = state.questions.filter { matches($0.value) }.map(\.key)
        var waiters: [CheckedContinuation<Outcome, Never>] = []
        for id in ids {
            waiters += state.questions[id]?.waiters.values.map { $0 } ?? []
            remove(id, from: &state)
        }
        return waiters
    }

    private static func openKey(_ session: String, _ app: ApprovalApp) -> String { session + "\n" + app.key }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    /// 32 hex characters from the system's random source.
    static func nonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return HelperWire.hex(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}
