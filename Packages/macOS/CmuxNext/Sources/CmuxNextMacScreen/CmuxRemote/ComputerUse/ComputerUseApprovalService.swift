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
    /// The dialogs that raise what agents may do: only the person answers them (DEBUG
    /// `debug.dialog` refuses to set, key or press them, `DebugDialog.userOnly`).
    public static let confirmModeDialogIdentifier = "cmux.dialog.computerUse.confirmMode"
    public static let approvalDialogIdentifier = "cmux.dialog.computerUse.approval"
    /// Computer Use setup's card for cmux Remote's two macOS permissions (``ComputerUseRemoteSetupCard``).
    public static let remoteSetupDialogIdentifier = "cmux.dialog.computerUse.remoteSetup"

    public let store: ComputerUseApprovalStore
    public let broker: ComputerUseApprovalBroker
    public let cards: ComputerUseApprovalCards
    /// The phone collector (held here: the broker keeps it weakly).
    private var phone: ComputerUseApprovalPhoneSink?
    private var settings: SettingsController?
    private var following: Task<Void, Never>?
    private weak var helper: ComputerUseHelperV2?

    /// `client`: this app's bundle id (each build keeps its own saved list).
    public init(client: String, file: ComputerUseApprovalFile? = nil, cards: ComputerUseApprovalCards = ComputerUseApprovalCards()) {
        store = ComputerUseApprovalStore(file: file ?? .standard(client: client))
        broker = ComputerUseApprovalBroker(store: store)
        self.cards = cards
        broker.presenter = cards
    }

    /// Answers `helper`'s approval questions and follows `computerUse.mode` (a change restarts
    /// the worker, which reads the new mode at start) and `computerUse.phoneAlwaysAllow`.
    public func start(helper: ComputerUseHelperV2, settings: SettingsController, phone: (any ComputerUsePhoneHost)?) {
        self.settings = settings
        self.helper = helper
        if let phone { connectPhone(phone) }
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

    /// Connects the owner's iPhone: questions go to its host (cmux-mobile-host), answers come back
    /// checked against the host's paired approval keys (this Mac's own list, never hostd's word).
    public func connectPhone(_ host: any ComputerUsePhoneHost) {
        let sink = ComputerUseApprovalPhoneSink(ask: { [weak host] request, always in
            host?.computerUseAsk(digest: request.digest, request: request.foundationObject, always: always)
        }, done: { [weak host] digest in host?.computerUseDone(digest: digest) })
        phone = sink
        broker.phone = sink
        broker.phoneApprovalKey = { [weak host] in host?.computerUseApprovalKey(phoneDeviceID: $0) }
        host.computerUseAnswered = { [weak self] phone, digest, decision, expiresAt, signature in
            self?.phoneAnswered(phone: phone, digest: digest, decision: decision, expiresAt: expiresAt, signature: signature)
        }
        broker.reaskPhone()
    }

    /// One phone answer as cmux-mobile-host forwarded it. False when it did not count.
    @discardableResult
    public func phoneAnswered(phone: String, digest: String, decision: String, expiresAt: Int64, signature: String?) -> Bool {
        guard let decision = ComputerUseApprovalDecision(rawValue: decision) else { return false }
        return broker.phoneAnswered(ComputerUseApprovalPhoneAnswer(phoneDeviceID: phone, digest: digest, decision: decision,
                                                                   expiresAt: expiresAt, signature: signature))
    }

    var workerState: String { helper?.stateName ?? "off" }
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

/// The owner's iPhone as the approvals see it (the App's iPhone host conforms).
@MainActor
public protocol ComputerUsePhoneHost: AnyObject {
    func computerUseAsk(digest: String, request: [String: Any], always: Bool)
    func computerUseDone(digest: String)
    func computerUseApprovalKey(phoneDeviceID: String) -> String?
    /// Set by the approvals: phone device id, digest, decision, expiry (Unix seconds), signature.
    var computerUseAnswered: (@MainActor (String, String, String, Int64, String?) -> Void)? { get set }
}
