#if os(iOS)
import CmuxMobileAuth
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

extension LiveCoordinator {
    /// The live coordinator of a signed-in account: RootView's, and the
    /// headless one a notification reply builds on a cold background launch.
    @MainActor
    static func forAccount(auth: CmuxMobileAuthModel, user: CmuxMobileAuthModel.User, base: URL, store: AppStore,
                           transport: CmuxMobileModel.TransportKind) -> LiveCoordinator {
        let api = LiveAPI(baseURL: base) { [auth] in try await auth.serviceAccessToken(forceRefresh: $0) }
        return LiveCoordinator(
            store: store,
            api: api,
            identity: DeviceIdentity.load(userID: user.id),
            userID: user.id,
            deviceName: UIDevice.current.name,
            transport: transport.link,
            relayOnly: DeveloperOptions.relayOnly,
            blockUDP: DeveloperOptions.blockUDP,
            dialer: FFIMacLinkDialer(),
            keys: PhoneKeys(userID: user.id),
            push: PushKeys.current()
        )
    }
}

/// Notification buttons, the content extension's outbox and "Couldn't reach"
/// retries (verify/rich-push.md, "Reply delivery").
///
/// - A background action (Deny, a text Reply) goes out over its Mac's link
///   without opening the app: RootView's coordinator when the app runs, else
///   a headless one built for the reply (a cold background launch connects no
///   scene, so there is no RootView). The headless coordinator stops once the
///   reply is out, before RootView may build its own: the hub keeps one
///   signaling socket per device, and two coordinators would replace each
///   other's.
/// - A foreground action (an option, Allow, an answer, the extension's Submit
///   and composer) opens the app on the chat; it is sent once the app is
///   active, unlocked and live, so Face ID can sign it.
/// - A failure that Retry can help posts "Couldn't reach <Mac>" with Retry.
@MainActor
@Observable
public final class PushReplies {
    public static let shared = PushReplies()

    /// Set by the app at launch (it owns the account model).
    @ObservationIgnored public var auth: CmuxMobileAuthModel?
    /// RootView's coordinator, while the app's scene runs.
    @ObservationIgnored private weak var live: LiveCoordinator?
    /// Foreground replies waiting for the app to be active, unlocked and live.
    private(set) var waiting: [PushReply] = []
    /// Background deliveries in flight on the headless coordinator (one at a
    /// time, review #8): it stops when the last one ends.
    private(set) var headlessRunning = false
    @ObservationIgnored private var headlessCount = 0
    @ObservationIgnored private var headlessCoordinator: LiveCoordinator?
    @ObservationIgnored private var draining = false
    /// The first drain after a cold attach waits as long as a cold launch does (review #7).
    @ObservationIgnored private var coldAttach = true
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// Settings → Require Face ID: Reply and Deny open the app (review L2).
    /// Read from the app's own defaults: launch never waits on the App Group
    /// (its container lookup blocked the main thread past the launch watchdog
    /// in a build signed without it, TestFlight 1.2.0 (20261026194905)).
    @ObservationIgnored private var faceIDSync = PushFaceIDSync(local: PushActions(defaults: .standard).requireFaceID)
    var requireFaceID: Bool { faceIDSync.local }
    /// The last write of the choice for the content extension (serial, off main).
    @ObservationIgnored private var sharedPreferenceWrite: Task<Void, Never>?
    /// Retries of "Couldn't reach" in the app's own storage (review H1).
    @ObservationIgnored let retries = PushRetryStore.app

    /// How long a cold background launch waits for sign-in, the team and the link.
    static let coldBudget: Duration = .seconds(12)

    init() {
        // The app coming back retries what waited (review #2), also when no scene modifier saw it.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainOutbox() }
        }
    }

    /// Registers every category (at launch, before any notification can arrive).
    public func registerCategories(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(PushActions(requireFaceID: requireFaceID).categories)
    }

    /// Settings → Require Face ID changed (AppLock): the buttons follow it.
    func setRequireFaceID(_ on: Bool) {
        // Called from every RootView body pass (AppLockController.init): an unchanged value writes nothing.
        let writes = faceIDSync.set(on)
        if writes.local { PushActions.setRequireFaceID(on, defaults: .standard) }
        if writes.shared {
            // The content extension reads it from the push keychain group (and the
            // App Group, when the build has one), written off the main thread in order.
            let previous = sharedPreferenceWrite
            sharedPreferenceWrite = Task.detached(priority: .utility) {
                await previous?.value
                PushSharedPreference.live(group: await PushAppGroup.resolved()).setRequireFaceID(on)
            }
        }
        guard writes.local else { return }
        // Only an app has a notification center (a test host has none, and asking it throws).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        registerCategories()
    }

    /// RootView's coordinator is live: send what waited for it, and what the
    /// content extension left while the app was not running (review #2).
    func attach(live: LiveCoordinator) {
        self.live = live
        drainOutbox()
    }

    /// Waits for a headless delivery to end (RootView calls it before it
    /// builds its coordinator), at most the cold budget.
    func headlessFinished() async {
        guard headlessRunning else { return }
        _ = await ObservationWait({ [weak self] in self?.headlessRunning != true }, budget: Self.coldBudget).value
    }

    // MARK: Responses

    /// What the app delegate read from a notification response.
    public struct Response: Sendable {
        public var actionIdentifier: String
        public var text: String?
        public var payload: PushPayload?
        /// A "Couldn't reach" notification's reply.
        public var retry: PushReply?
        /// False: the push may open the app but no button acts (an unsealed push
        /// from a Mac that seals, or a stale one; PR B security review H1).
        public var actionable: Bool
        /// Photos and files the long look's "+" staged for Reply (outbox file names).
        public var attachments: [String] = []

        public init(actionIdentifier: String, text: String?, payload: PushPayload?, retry: PushReply?, actionable: Bool = true) {
            self.actionIdentifier = actionIdentifier
            self.text = text
            self.payload = payload
            self.retry = retry
            self.actionable = actionable
        }

        /// What a notification response says. A retry comes only from the
        /// app's own store and only for a notification the app posted itself:
        /// a remote push never carries a reply (review H1).
        /// A push is read through `gate`: a sealed one is opened again from its
        /// box, an unsealed one from a Mac that seals acts on nothing.
        public init(actionIdentifier: String, text: String?, userInfo: [AnyHashable: Any], fromPush: Bool, retries: PushRetryStore?,
                    shown: PushTrustGate.Shown? = nil, gate: PushTrustGate = .current(), now: Date = Date()) {
            let payload: PushPayload?
            let actionable: Bool
            switch gate.verdict(userInfo: userInfo, shown: shown, now: now) {
            case .trusted(let p): (payload, actionable) = (p, true)
            case .openOnly(let p): (payload, actionable) = (p, false)
            case .refused: (payload, actionable) = (nil, false)
            }
            self.init(actionIdentifier: actionIdentifier, text: text, payload: payload,
                      retry: retries?.resolve(userInfo: userInfo, fromPush: fromPush), actionable: actionable)
        }
    }

    /// What a response does (pure, tested).
    enum Outcome: Equatable {
        case nothing
        case open(PushPayload)
        case foreground(PushReply, open: PushPayload?)
        case background(PushReply)
    }

    static func outcome(_ response: Response, requireFaceID: Bool = false) -> Outcome {
        let identifier = response.actionIdentifier
        if let retry = response.retry {
            // "Couldn't reach" → Retry, or a tap on it: send again in the foreground.
            return identifier == UNNotificationDismissActionIdentifier ? .nothing : .foreground(retry, open: nil)
        }
        guard let payload = response.payload, identifier != UNNotificationDismissActionIdentifier else { return .nothing }
        if identifier == UNNotificationDefaultActionIdentifier { return .open(payload) }
        // Not trusted to act: a button only opens the app (where nothing is sent for it).
        guard response.actionable else { return .open(payload) }
        guard let button = PushAction(identifier: identifier) else { return .nothing }
        if button == .answer { return .open(payload) }
        let opensApp = PushActions(requireFaceID: requireFaceID).opensApp(button)
        guard let reply = PushReply(payload: payload, button: button, text: response.text, attachments: response.attachments) else {
            return opensApp ? .open(payload) : .nothing
        }
        return opensApp ? .foreground(reply, open: payload) : .background(reply)
    }

    /// What the long look staged for the notification `requestID`'s Reply (off the main thread).
    static func stagedAttachments(for requestID: String) async -> [String] {
        guard let outbox = PushOutbox(group: await PushAppGroup.resolved()) else { return [] }
        return await Task.detached(priority: .userInitiated) { outbox.takeStaged(for: requestID) }.value
    }

    /// One notification response (the app delegate). Returns once a
    /// background reply was delivered or failed: iOS keeps the app awake
    /// until the delegate returns.
    public func handle(_ response: Response) async {
        switch Self.outcome(response, requireFaceID: requireFaceID) {
        case .nothing:
            break
        case .open(let payload):
            NotificationRouter.shared.open(payload)
        case .foreground(let reply, let payload):
            if let payload { NotificationRouter.shared.open(payload) } else { NotificationRouter.shared.open(reply: reply) }
            enqueueForeground(reply)
        case .background(let reply):
            if case .text(_, let names) = reply.action {
                log.info("push reply: \(reply.kind.rawValue, privacy: .public) text reply with \(names.count, privacy: .public) attachment(s)")
            }
            await deliverInBackground(reply)
        }
    }

    /// The content extension's outbox and anything waiting: on launch and on
    /// every return to the foreground.
    /// The App Group and its files are read off the main thread.
    public func drainOutbox() {
        drain()
        Task { await takeOutbox() }
    }

    private func takeOutbox() async {
        guard let outbox = PushOutbox(group: await PushAppGroup.resolved()) else { return }
        // `take` claims each file by renaming it, so two drains never both take one reply.
        let replies = await Task.detached(priority: .userInitiated) { outbox.takeAll() }.value
        for reply in replies {
            NotificationRouter.shared.open(reply: reply)
            // Text into a terminal never comes from the outbox: anything in
            // it may have been written while the phone was locked (PR B
            // security review H2). Only the unlock-gated Reply button sends it.
            if Self.fromOutboxRefused(reply) {
                log.error("push reply: a terminal reply in the outbox was dropped")
                continue
            }
            waiting.append(reply)
        }
        if !replies.isEmpty { drain() }
    }

    /// Outbox replies the app never sends: text into a terminal.
    static func fromOutboxRefused(_ reply: PushReply) -> Bool {
        if case .text = reply.action, reply.kind == .terminal { return true }
        return false
    }

    func enqueueForeground(_ reply: PushReply) {
        waiting.append(reply)
        drain()
    }

    /// Sends the waiting replies once the app is active, unlocked and live.
    func drain() {
        guard !draining, !waiting.isEmpty, let live, UIApplication.shared.applicationState == .active,
              !NotificationRouter.shared.appLocked else { return }
        draining = true
        let batch = waiting
        waiting = []
        let budget = coldAttach ? Self.coldBudget : LiveCoordinator.pushReplyBudget
        coldAttach = false
        Task {
            for reply in batch {
                await self.send(reply, on: live, budget: budget)
            }
            self.draining = false
            self.drain()
        }
    }

    /// The app became active or unlocked.
    public func appStateChanged() { drain() }

    private func deliverInBackground(_ reply: PushReply) async {
        if let live {
            await send(reply, on: live, budget: LiveCoordinator.pushReplyBudget)
            return
        }
        // One headless coordinator for every reply of a cold launch (the hub keeps one socket per device).
        headlessCount += 1
        headlessRunning = true
        defer {
            headlessCount -= 1
            if headlessCount == 0 {
                headlessCoordinator?.stop()
                headlessCoordinator = nil
                headlessRunning = false
            }
        }
        if headlessCoordinator == nil { headlessCoordinator = await headless() }
        guard let coordinator = headlessCoordinator else {
            await postCouldNotReach(reply, reason: String(localized: "Open cmux to sign in."))
            return
        }
        await send(reply, on: coordinator, budget: Self.coldBudget)
    }

    /// A coordinator for a cold background launch: the account restored from
    /// the keychain, its teams, then its Macs.
    private func headless() async -> LiveCoordinator? {
        guard let auth, !auth.isMock else { return nil }
        _ = await ObservationWait({ auth.isResolved }, budget: .seconds(3)).value
        guard auth.isSignedIn, let user = auth.user, let base = auth.apiBaseURL else { return nil }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [])
        let coordinator = LiveCoordinator.forAccount(auth: auth, user: user, base: base, store: store, transport: SettingsStore().transport)
        await auth.loadTeams()
        coordinator.applyAccountTeams(auth.teams, selectedID: auth.selectedTeamID)
        return coordinator
    }

    private func send(_ reply: PushReply, on live: LiveCoordinator, budget: Duration) async {
        do {
            try await live.deliver(reply, budget: budget)
            if let eventId = reply.eventId { clearDelivered(eventId: eventId) }
            // Its photos leave the App Group once sent (review L4).
            if case .text(_, let names) = reply.action, !names.isEmpty, let outbox = PushOutbox(group: await PushAppGroup.resolved(timeout: PushAppGroupResolver.cleanupTimeout)) {
                await Task.detached(priority: .utility) { outbox.removeAttachments(names) }.value
            }
        } catch let failure as LiveCoordinator.PushReplyFailure {
            switch failure.reason {
            case .unreachable:
                // The link missed its budget: the service's mailbox, sealed to the Mac (PR B).
                if await sendViaMailbox(reply, on: live) { return }
                await postCouldNotReach(reply, reason: nil)
            case .refused(let message):
                await postNotice(reply, title: String(localized: "Not sent to \(reply.macName ?? String(localized: "your Mac"))"), body: message)
            case .cancelled:
                break
            }
        } catch {
            await postCouldNotReach(reply, reason: nil)
        }
    }

    /// When the phone asks whether the Mac applied a mailbox reply: soon, then
    /// less often, about 15 s in all (PR B review 9).
    static let mailboxCheckDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()

    /// Sends `reply` through the mailbox; true when the service took it.
    /// A Mac that was online is asked once, a moment later, whether it
    /// applied it; a refusal is posted with its reason.
    private func sendViaMailbox(_ reply: PushReply, on live: LiveCoordinator) async -> Bool {
        let outcome: LiveCoordinator.MailboxOutcome
        do {
            outcome = try await live.deliverViaMailbox(reply)
        } catch let failure as LiveCoordinator.PushReplyFailure {
            switch failure.reason {
            case .unreachable: return false
            case .cancelled: return true
            case .refused(let message):
                await postNotice(reply, title: String(localized: "Not sent to \(reply.macName ?? String(localized: "your Mac"))"), body: message)
                return true
            }
        } catch {
            return false
        }
        if let eventId = reply.eventId { clearDelivered(eventId: eventId) }
        let mac = reply.macName ?? String(localized: "your Mac")
        var last: LiveAPI.MailboxState?
        for delay in Self.mailboxCheckDelays {
            try? await clock.sleep(for: delay)
            guard let state = await live.mailboxState(of: reply) else { continue }
            last = state
            switch Self.mailboxVerdict(state, signed: live.signedMailboxOutcome(reply, state: state)) {
            case .applied:
                return true
            case .refused(let message):
                await postNotice(reply, title: String(localized: "Not sent to \(mac)"), body: message)
                return true
            case .expired:
                await postCouldNotReach(reply, reason: String(localized: "\(mac) didn't pick up your reply in time."))
                return true
            case .pending:
                continue
            }
        }
        // The Mac has not said: the service holds it, but nobody confirmed it (review M3).
        if outcome == .queued || last?.state == "queued" || last != nil {
            await postNotice(reply, title: String(localized: "Not confirmed by \(mac)"),
                             body: String(localized: "Your reply is waiting for \(mac) to come online. It expires in 10 minutes."))
        }
        return true
    }

    /// What a mailbox state means for the person.
    enum MailboxVerdict: Equatable {
        case applied
        case refused(String)
        case expired
        /// Still queued, or an outcome without the Mac's valid signature (the
        /// service's word alone is never taken as applied).
        case pending
    }

    static func mailboxVerdict(_ state: LiveAPI.MailboxState, signed: (applied: Bool, reason: String?)?) -> MailboxVerdict {
        if state.state == "expired" { return .expired }
        guard let signed else { return .pending }
        if signed.applied { return .applied }
        return .refused(mailboxRefusal(signed.reason))
    }

    /// What the phone says for the Mac's mailbox refusal reason (PROTOCOL.md).
    /// A repeat of a reply the Mac applied comes back as applied (its first
    /// outcome, signed), never as `replayed`; `replayed` is another reply's
    /// nonce, a refusal (PR B security review M4).
    static func mailboxRefusal(_ reason: String?) -> String {
        switch reason {
        case "expired": String(localized: "Your reply arrived too late.")
        case "not_pending": String(localized: "This was already answered.")
        case "not_paired": String(localized: "This iPhone isn't paired with that Mac any more.")
        default: String(localized: "Your Mac didn't accept the reply.")
        }
    }

    /// The answered notification leaves Notification Center.
    private func clearDelivered(eventId: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { PushPayload(userInfo: $0.request.content.userInfo)?.eventId == eventId }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// "Couldn't reach <Mac>" with Retry, carrying the reply.
    func postCouldNotReach(_ reply: PushReply, reason: String?) async {
        let mac = reply.macName ?? String(localized: "your Mac")
        log.error("push reply: couldn't reach the Mac")
        await postNotice(reply, title: String(localized: "Couldn't reach \(mac)"),
                         body: reason ?? String(localized: "Your reply wasn't sent. Tap Retry to send it again."), retry: true)
    }

    private func postNotice(_ reply: PushReply, title: String, body: String, retry: Bool = false) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = reply.sessionId.map { "\(reply.mac):\($0)" } ?? reply.mac
        if retry {
            content.categoryIdentifier = PushCategory.retry.rawValue
            // Only the id: the reply stays in the app's own storage (review H1).
            do {
                try retries?.put(reply)
                content.userInfo = reply.retryUserInfo
            } catch {
                log.error("push reply: retry not saved")
            }
        }
        let request = UNNotificationRequest(identifier: "reply-\(reply.id.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
