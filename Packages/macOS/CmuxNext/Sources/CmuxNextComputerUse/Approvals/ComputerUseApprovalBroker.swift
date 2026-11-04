// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
public import Observation
import CmuxNextWakeups
import os

/// One question waiting for a person.
public nonisolated struct ComputerUseApprovalPending: Sendable, Equatable, Identifiable {
    /// The first 16 hex digits of the digest (what the CLI and the card name).
    public var id: String { request.id }
    public var request: ComputerUseApprovalRequest
    /// The worker link it came on, and its id on that link.
    var link: Int
    var questionID: Int
}

/// Shows and withdraws the approval cards (the App's non-activating panels).
@MainActor
public protocol ComputerUseApprovalPresenting: AnyObject {
    /// Shows `pending`'s card, or brings it forward again when it shows.
    func show(_ pending: ComputerUseApprovalPending, broker: ComputerUseApprovalBroker)
    /// Takes `id`'s card away (answered elsewhere, cancelled, expired).
    func withdraw(_ id: String)
}

/// The Mac app's side of Computer Use app approvals (docs/computer-use-approvals.md): it reads
/// the worker's `app_approval` questions, shows a card per question, asks the owner's phone,
/// takes the first valid answer (single use, bound to the request digest, before
/// `answerable_until_ms`), saves an Always in this client's ``ComputerUseApprovalStore`` and
/// keeps every worker link told of the saved list (`approved_apps`, `revoke`).
///
/// Nothing here decides by itself: a decision comes only from a person's press on the card
/// (``decide(_:decision:)``) or a phone answer whose Face ID signature verifies against that
/// phone's approval key in this app's own paired list (``phoneAnswered(_:)``).
@MainActor @Observable
public final class ComputerUseApprovalBroker {
    public private(set) var pending: [ComputerUseApprovalPending] = []
    @ObservationIgnored public let store: ComputerUseApprovalStore
    @ObservationIgnored public weak var presenter: (any ComputerUseApprovalPresenting)?
    @ObservationIgnored public weak var phone: (any ComputerUseApprovalPhoneRelay)?
    /// `computerUse.phoneAlwaysAllow` now.
    @ObservationIgnored public var phoneAlwaysAllow: @MainActor () -> Bool = { false }
    /// The paired phone's approval key (X9.63 hex) by link device id, from this app's own list.
    @ObservationIgnored public var phoneApprovalKey: @MainActor (String) -> String? = { _ in nil }
    @ObservationIgnored private let nowMs: @Sendable () -> Int64
    @ObservationIgnored private var links: [Int: AsyncStream<Data>.Continuation] = [:]
    @ObservationIgnored private var nextLink = 1
    @ObservationIgnored private var timers: [String: DemandTimer] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-approvals")

    public init(store: ComputerUseApprovalStore,
                nowMs: @escaping @Sendable () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }) {
        self.store = store
        self.nowMs = nowMs
        store.onChange = { [weak self] apps in self?.broadcast(ComputerUseApprovalWire.approvedApps(apps.map(\.app))) }
    }

    // MARK: Links

    /// A worker's host link came up: its lines go to `outbox`, in order. It hears the saved list
    /// at once. Returns the link's id for ``receive(_:link:)`` and ``detach(_:)``.
    public func attach(_ outbox: AsyncStream<Data>.Continuation) -> Int {
        let id = nextLink
        nextLink += 1
        links[id] = outbox
        outbox.yield(ComputerUseApprovalWire.approvedApps(store.apps.map(\.app)))
        return id
    }

    /// The link closed: its questions are gone (the worker ended their sessions).
    public func detach(_ link: Int) {
        links.removeValue(forKey: link)?.finish()
        for entry in pending where entry.link == link { settle(entry, answer: nil) }
    }

    /// One approval line from link `link`.
    func receive(_ incoming: ComputerUseApprovalWire.Incoming, link: Int) {
        switch incoming {
        case .malformed(let id):
            logger.error("Computer Use approval question \(id, privacy: .public) failed its checks; refused")
            send(ComputerUseApprovalWire.unanswered(id: id), to: link)
        case .cancel(let id):
            if let entry = pending.first(where: { $0.link == link && $0.questionID == id }) { settle(entry, answer: nil, tellWorker: false) }
        case .question(let id, let request):
            ask(request, id: id, link: link)
        }
    }

    /// The contract's answerable window (10 minutes) plus a minute of clock skew: a longer one is refused.
    static let maximumWindowMs: Int64 = 660_000

    /// Whether this app may ask a person about `request` at `now`: this client's question, inside
    /// the contract's window, and never about cmux itself (the worker refuses those too).
    func admits(_ request: ComputerUseApprovalRequest, now: Int64) -> Bool {
        let target = request.target.bundleID ?? ""
        return request.client == store.client && request.isAnswerable(nowMs: now)
            && request.answerableUntilMs - request.createdMs <= Self.maximumWindowMs
            && request.answerableUntilMs <= now + Self.maximumWindowMs
            && target != store.client && !target.hasPrefix("com.cmuxterm.")
    }

    private func ask(_ request: ComputerUseApprovalRequest, id: Int, link: Int) {
        let now = nowMs()
        // Saved lists are per client: a question for another client is not this app's to answer.
        guard admits(request, now: now),
              !pending.contains(where: { $0.request.digest == request.digest }) else {
            if !pending.contains(where: { $0.request.digest == request.digest }) {
                send(ComputerUseApprovalWire.unanswered(id: id), to: link)
            }
            return
        }
        let entry = ComputerUseApprovalPending(request: request, link: link, questionID: id)
        pending.append(entry)
        let timer = DemandTimer(owner: "computer-use.approval-expiry")
        timers[entry.id] = timer
        timer.schedule(after: .milliseconds(max(0, request.answerableUntilMs - now))) { @MainActor [weak self] in
            self?.expire(entry.id)
        }
        presenter?.show(entry, broker: self)
        phone?.ask(request, allowsAlways: phoneAlwaysAllow())
    }

    // MARK: Decisions

    /// A person's press on the card. False when the question is gone (answered, expired).
    @discardableResult
    public func decide(_ id: String, decision: ComputerUseApprovalDecision) -> Bool {
        guard let entry = pending.first(where: { $0.id == id }), entry.request.isAnswerable(nowMs: nowMs()) else { return false }
        if decision == .always { store.add(entry.request.target, via: .mac, nowMs: nowMs()) }
        settle(entry, answer: (decision, .mac))
        return true
    }

    /// A phone's answer from cmux-mobile-host. Applied only when it is for a pending question,
    /// in time, signed by that paired phone's approval key (an allow), and an Always only while
    /// `computerUse.phoneAlwaysAllow` is on. Returns whether it counted.
    @discardableResult
    public func phoneAnswered(_ answer: ComputerUseApprovalPhoneAnswer) -> Bool {
        let now = nowMs()
        guard let entry = pending.first(where: { $0.request.digest == answer.digest }), entry.request.isAnswerable(nowMs: now),
              answer.decision != .always || phoneAlwaysAllow(),
              answer.isValid(approvalKey: phoneApprovalKey(answer.phoneDeviceID), nowSeconds: now / 1000) else {
            logger.notice("Computer Use phone answer for \(answer.digest.prefix(16), privacy: .public) refused")
            return false
        }
        if answer.decision == .always { store.add(entry.request.target, via: .phone, nowMs: now) }
        settle(entry, answer: (answer.decision, .phone))
        return true
    }

    /// The question passed `answerable_until_ms`: it goes, and the worker hears `ok:false`.
    func expire(_ id: String) {
        guard let entry = pending.first(where: { $0.id == id }) else { return }
        settle(entry, answer: nil)
    }

    /// Ends `entry` once: answers the worker (or `ok:false`), withdraws the card and the phone ask.
    private func settle(_ entry: ComputerUseApprovalPending, answer: (ComputerUseApprovalDecision, ComputerUseApprovalVia)?,
                        tellWorker: Bool = true) {
        guard let index = pending.firstIndex(where: { $0.request.digest == entry.request.digest }) else { return }
        pending.remove(at: index)
        timers.removeValue(forKey: entry.id)?.cancel()
        if tellWorker {
            let line = answer.map { ComputerUseApprovalWire.answer(id: entry.questionID, decision: $0.0, digest: entry.request.digest, via: $0.1) }
                ?? ComputerUseApprovalWire.unanswered(id: entry.questionID)
            send(line, to: entry.link)
        }
        presenter?.withdraw(entry.id)
        phone?.done(digest: entry.request.digest)
    }

    // MARK: Controls

    /// Shows `id`'s card again (`computer_use.approvals.prompt`); never decides. False: no such question.
    @discardableResult
    public func prompt(_ id: String) -> Bool {
        guard let entry = pending.first(where: { $0.id == id || $0.request.digest == id }) else { return false }
        presenter?.show(entry, broker: self)
        return true
    }

    /// Denies `id` from the CLI or MCP (`computer_use.approvals.deny`). A deny only lowers trust, so
    /// it needs no protected collector. False: no such question, or it is no longer answerable.
    @discardableResult
    public func deny(_ id: String) -> Bool {
        guard let entry = pending.first(where: { $0.id == id || $0.request.digest == id }),
              entry.request.isAnswerable(nowMs: nowMs()) else { return false }
        settle(entry, answer: (.deny, .cli))
        return true
    }

    /// Revokes saved approvals (nil: all) and tells every worker. Returns how many were removed.
    @discardableResult
    public func revoke(_ app: ComputerUseApprovalApp?) -> Int {
        let removed = store.revoke(app)
        // Sent even when the list had no such app: the worker also drops session grants for it.
        broadcast(ComputerUseApprovalWire.revoke(app))
        return removed
    }

    /// A phone ask again for every pending question (a restarted iPhone host, the setting changed).
    public func reaskPhone() {
        for entry in pending { phone?.ask(entry.request, allowsAlways: phoneAlwaysAllow()) }
    }

    private func send(_ line: Data, to link: Int) { links[link]?.yield(line) }

    private func broadcast(_ line: Data) {
        for outbox in links.values { outbox.yield(line) }
    }
}
