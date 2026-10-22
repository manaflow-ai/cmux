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
            keys: PhoneKeys(userID: user.id)
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
    /// Whether a headless coordinator is delivering now.
    private(set) var headlessRunning = false
    @ObservationIgnored private var draining = false

    /// How long a cold background launch waits for sign-in, the team and the link.
    static let coldBudget: Duration = .seconds(12)

    init() {}

    /// Registers every category (at launch, before any notification can arrive).
    public func registerCategories(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(PushActions().categories)
    }

    /// RootView's coordinator is live: send what waited for it.
    func attach(live: LiveCoordinator) {
        self.live = live
        drain()
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

        public init(actionIdentifier: String, text: String?, payload: PushPayload?, retry: PushReply?) {
            self.actionIdentifier = actionIdentifier
            self.text = text
            self.payload = payload
            self.retry = retry
        }
    }

    /// What a response does (pure, tested).
    enum Outcome: Equatable {
        case nothing
        case open(PushPayload)
        case foreground(PushReply, open: PushPayload?)
        case background(PushReply)
    }

    static func outcome(_ response: Response) -> Outcome {
        let identifier = response.actionIdentifier
        if let retry = response.retry {
            // "Couldn't reach" → Retry, or a tap on it: send again in the foreground.
            return identifier == UNNotificationDismissActionIdentifier ? .nothing : .foreground(retry, open: nil)
        }
        guard let payload = response.payload, identifier != UNNotificationDismissActionIdentifier else { return .nothing }
        if identifier == UNNotificationDefaultActionIdentifier { return .open(payload) }
        guard let button = PushAction(identifier: identifier) else { return .nothing }
        if button == .answer { return .open(payload) }
        guard let reply = PushReply(payload: payload, button: button, text: response.text) else {
            return button.opensApp ? .open(payload) : .nothing
        }
        return button.opensApp ? .foreground(reply, open: payload) : .background(reply)
    }

    /// One notification response (the app delegate). Returns once a
    /// background reply was delivered or failed: iOS keeps the app awake
    /// until the delegate returns.
    public func handle(_ response: Response) async {
        switch Self.outcome(response) {
        case .nothing:
            break
        case .open(let payload):
            NotificationRouter.shared.open(payload)
        case .foreground(let reply, let payload):
            if let payload { NotificationRouter.shared.open(payload) } else { NotificationRouter.shared.open(reply: reply) }
            enqueueForeground(reply)
        case .background(let reply):
            await deliverInBackground(reply)
        }
    }

    /// The content extension's outbox and anything waiting: on launch and on
    /// every return to the foreground.
    public func drainOutbox() {
        if let outbox = PushOutbox(group: .current()) {
            for reply in outbox.takeAll() {
                NotificationRouter.shared.open(reply: reply)
                waiting.append(reply)
            }
        }
        drain()
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
        Task {
            for reply in batch {
                await self.send(reply, on: live, budget: LiveCoordinator.pushReplyBudget)
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
        guard let coordinator = await headless() else {
            await postCouldNotReach(reply, reason: String(localized: "Open cmux to sign in."))
            return
        }
        headlessRunning = true
        defer {
            coordinator.stop()
            headlessRunning = false
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
        } catch let failure as LiveCoordinator.PushReplyFailure {
            switch failure.reason {
            case .unreachable:
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
            content.userInfo = reply.userInfo
        }
        let request = UNNotificationRequest(identifier: "reply-\(reply.id.uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
