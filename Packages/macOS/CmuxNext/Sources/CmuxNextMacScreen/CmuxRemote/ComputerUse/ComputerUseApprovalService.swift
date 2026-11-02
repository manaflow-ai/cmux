public import CmuxNextComputerUse
import CmuxNextCompat
public import CmuxNextSettings
import os

private let approvalsLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-approvals")

/// Computer Use app approvals in the app (docs/computer-use-approvals.md): this client's saved
/// list, the broker that answers the worker, the cards, and the phone collector. The App makes
/// one, starts it with the Computer Use worker and the settings, and connects the iPhone host.
@MainActor
public final class ComputerUseApprovalService {
    public let store: ComputerUseApprovalStore
    public let broker: ComputerUseApprovalBroker
    public let cards: ComputerUseApprovalCards
    /// The phone collector (held here: the broker keeps it weakly).
    private var phone: ComputerUseApprovalPhoneSink?
    private var settings: SettingsController?
    private var following: Task<Void, Never>?
    private var listening: Task<Void, Never>?

    /// `client`: this app's bundle id (each build keeps its own saved list).
    public init(client: String, file: ComputerUseApprovalFile? = nil, cards: ComputerUseApprovalCards = ComputerUseApprovalCards()) {
        store = ComputerUseApprovalStore(file: file ?? .standard(client: client))
        broker = ComputerUseApprovalBroker(store: store)
        self.cards = cards
        broker.presenter = cards
    }

    /// Answers `helper`'s approval questions and follows `computerUse.mode` (a change restarts
    /// the worker, which reads the new mode at start) and `computerUse.phoneAlwaysAllow`.
    public func start(helper: ComputerUseHelperV2, settings: SettingsController) {
        self.settings = settings
        // task-owner: one read of the saved list, off the main actor.
        Task { await store.load() }
        helper.approvals = broker
        helper.permissionMode = { [weak settings] in settings?.snapshot.computerUse.mode ?? .ask }
        broker.phoneAlwaysAllow = { [weak settings] in settings?.snapshot.computerUse.phoneAlwaysAllow ?? false }
        following?.cancel()
        // task-owner: lives with the app; follows the two settings.
        following = Task { [weak self, weak settings, weak helper] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            var last: (mode: ComputerUseMode, always: Bool)?
            for await next in ObservationStream({ (settings.snapshot.computerUse.mode, settings.snapshot.computerUse.phoneAlwaysAllow) }) {
                guard let self else { return }
                defer { last = (next.0, next.1) }
                guard let previous = last else { continue }
                if previous.always != next.1 { broker.reaskPhone() }
                if previous.mode != next.0 {
                    approvalsLogger.notice("computerUse.mode is \(next.0.rawValue, privacy: .public); restarting the Computer Use worker")
                    await helper?.restartForModeChange()
                }
            }
        }
    }

    /// Connects the owner's iPhone: `ask`/`done` reach cmux-mobile-host; answers come back
    /// through ``phoneAnswered(phone:digest:decision:expiresAt:signature:)``, checked against
    /// `approvalKey` (this Mac's own paired list).
    public func connectPhone(ask: @escaping @MainActor (ComputerUseApprovalRequest, Bool) -> Void,
                             done: @escaping @MainActor (String) -> Void,
                             approvalKey: @escaping @MainActor (String) -> String?) {
        let sink = ComputerUseApprovalPhoneSink(ask: ask, done: done)
        phone = sink
        broker.phone = sink
        broker.phoneApprovalKey = approvalKey
        broker.reaskPhone()
    }

    /// One phone answer as cmux-mobile-host forwarded it. False when it did not count.
    @discardableResult
    public func phoneAnswered(phone: String, digest: String, decision: String, expiresAt: Int64, signature: String?) -> Bool {
        guard let decision = ComputerUseApprovalDecision(rawValue: decision) else { return false }
        return broker.phoneAnswered(ComputerUseApprovalPhoneAnswer(phoneDeviceID: phone, digest: digest, decision: decision,
                                                                   expiresAt: expiresAt, signature: signature))
    }

    /// Reads phone answers from `answers` for the app's lifetime.
    public func listen<Answer: Sendable>(_ answers: AsyncStream<Answer>, map: @escaping @Sendable (Answer)
        -> (phone: String, digest: String, decision: String, expiresAt: Int64, signature: String?)) {
        listening?.cancel()
        // task-owner: lives with the app; one main-actor hop per phone answer.
        listening = Task { [weak self] in
            for await element in answers {
                let answer = map(element)
                self?.phoneAnswered(phone: answer.phone, digest: answer.digest, decision: answer.decision,
                                    expiresAt: answer.expiresAt, signature: answer.signature)
            }
        }
    }

    var mode: ComputerUseMode { settings?.snapshot.computerUse.mode ?? .ask }
    var phoneAlwaysAllow: Bool { settings?.snapshot.computerUse.phoneAlwaysAllow ?? false }
    var settingsController: SettingsController? { settings }
}

/// The phone collector as two closures (the App wires them to the iPhone host).
@MainActor
final class ComputerUseApprovalPhoneSink: ComputerUseApprovalPhoneRelay {
    private let askPhone: @MainActor (ComputerUseApprovalRequest, Bool) -> Void
    private let donePhone: @MainActor (String) -> Void

    init(ask: @escaping @MainActor (ComputerUseApprovalRequest, Bool) -> Void, done: @escaping @MainActor (String) -> Void) {
        askPhone = ask
        donePhone = done
    }

    func ask(_ request: ComputerUseApprovalRequest, allowsAlways: Bool) { askPhone(request, allowsAlways) }
    func done(digest: String) { donePhone(digest) }
}
