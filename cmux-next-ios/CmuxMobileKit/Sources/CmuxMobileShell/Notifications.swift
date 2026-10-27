#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileSettings
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

/// What a push from the Mac points at (PROTOCOL.md "Push notifications"):
/// the screen a tap opens, on that push's Mac.
public struct NotificationRoute: Equatable, Sendable {
    public var kind: String
    public var mac: String?
    public var sessionID: String?
    public var workspaceID: String?
    public var tabID: String?
    public var conversationID: String?

    public init(kind: String, mac: String? = nil, sessionID: String? = nil, workspaceID: String? = nil, tabID: String? = nil,
                conversationID: String? = nil) {
        self.kind = kind
        self.mac = mac
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.conversationID = conversationID
    }

    init(_ payload: PushPayload) {
        self.init(kind: payload.kind.rawValue, mac: payload.mac, sessionID: payload.sessionId, workspaceID: payload.workspaceId,
                  tabID: payload.tabId, conversationID: payload.conversationId)
    }

    init(_ reply: PushReply) {
        self.init(kind: reply.kind.rawValue, mac: reply.mac, sessionID: reply.sessionId, workspaceID: reply.workspaceId,
                  tabID: reply.tabId, conversationID: reply.conversationId)
    }

    /// Reads `userInfo["cmuxMobile"]`; nil for anything else.
    init?(userInfo: [AnyHashable: Any]) {
        guard let payload = PushPayload(userInfo: userInfo) else { return nil }
        self.init(payload)
    }
}

/// Hands notification taps to the shell, and asks it whether a notification's
/// screen is already on screen (then no banner shows). A route set before the
/// shell exists (a cold launch) waits here until it does.
@MainActor
@Observable
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// A tapped notification the shell has not opened yet.
    public private(set) var pending: NotificationRoute?
    /// When `pending` was set: past `waitBudget` it opens the Feed (review #4).
    @ObservationIgnored private(set) var pendingSince: ContinuousClock.Instant?
    /// How long a route waits for its Mac's tree before it settles for the Feed.
    static let waitBudget: Duration = .seconds(10)
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()
    /// Settings → Require Face ID has the app locked (AppLock): replies that
    /// need Face ID wait, so the two prompts never overlap.
    public internal(set) var appLocked = false {
        didSet { if !appLocked { PushReplies.shared.appStateChanged() } }
    }
    /// Set by the shell: whether this route's screen is what the user is looking at.
    @ObservationIgnored var isShowing: (NotificationRoute) -> Bool = { _ in false }

    init() {}

    func open(_ payload: PushPayload) {
        set(NotificationRoute(payload))
    }

    func open(reply: PushReply) {
        set(NotificationRoute(reply))
    }

    /// Waits for `route`, at most `waitBudget`: then it is tried once more, as expired.
    func set(_ route: NotificationRoute?, at now: ContinuousClock.Instant = .now) {
        pending = route
        pendingSince = route == nil ? nil : now
        guard let route else { return }
        let clock = clock
        Task { @MainActor [weak self] in
            try? await clock.sleep(for: Self.waitBudget)
            guard let self, self.pending == route else { return }
            self.expired += 1
        }
    }

    /// Bumped when a waiting route's budget ends (the shell then opens the Feed).
    public private(set) var expired = 0

    func isExpired(at now: ContinuousClock.Instant = .now) -> Bool {
        pendingSince.map { now - $0 > Self.waitBudget } ?? false
    }

    /// The route was opened (or settled for the Feed).
    func opened() {
        set(nil)
    }

    /// The person went to another screen while a route waited: it is dropped.
    func userNavigated() {
        if pending != nil { set(nil) }
    }
}

/// The app delegate: remote-notification registration and notification
/// presentation, taps and buttons. Notification permission is asked in setup
/// (or Settings → Notifications); once granted, every launch registers so the
/// token stays current.
@MainActor
public final class CmuxMobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // The App Group resolves once, off the main thread (its lookup is a synchronous XPC).
        PushAppGroup.prime()
        PushReplies.shared.registerCategories()
        #if DEBUG && targetEnvironment(simulator)
        SimulatedServiceExtension.deliverIfAsked()
        SimulatedServiceExtension.registerStandInTokenIfAsked()
        #endif
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if BuildCapabilities.current.push, [.authorized, .provisional, .ephemeral].contains(status) { application.registerForRemoteNotifications() }
        }
        return true
    }

    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.didRegister(deviceToken: deviceToken)
    }

    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    /// A push while the app is in front. The completion handler form, called on
    /// the main thread, like `didReceive`: the async form of a
    /// UNUserNotificationCenterDelegate method calls UIKit's handler from a
    /// background thread (NotificationDelegateThreadTests).
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let route = NotificationRoute(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            let showing = route.map { NotificationRouter.shared.isShowing($0) } ?? false
            completionHandler(showing ? [] : [.banner, .list, .sound])
        }
    }

    /// Taps and buttons. iOS keeps a background launch alive until the
    /// completion handler runs, so a background reply is delivered (or fails)
    /// first. The handler must run on the main thread: UIKit updates the app's
    /// snapshot in it and aborts off the main thread (verify/push-matrix.md,
    /// failure 2: the async form returned on a background thread and every
    /// notification button crashed the app; TestFlight 1.2.0 (20261023213712)
    /// crashed the same way on a plain tap). Never make this `async`:
    /// NotificationDelegateThreadTests fails if the handler leaves the main thread.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        // Only Sendable values cross to the main actor.
        let content = response.notification.request.content
        let userInfo = content.userInfo
        let shown = PushTrustGate.Shown(title: content.title, subtitle: content.subtitle, body: content.body,
                                        category: content.categoryIdentifier)
        // Only the app's own (local) notifications may carry a retry (review H1).
        let fromPush = response.notification.request.trigger is UNPushNotificationTrigger
        var read = PushReplies.Response(actionIdentifier: response.actionIdentifier,
                                        text: (response as? UNTextInputNotificationResponse)?.userText,
                                        userInfo: userInfo, fromPush: fromPush, retries: PushRetryStore.app, shown: shown)
        // Reply sends what the long look's "+" attached to this notification with its text.
        let requestID = response.notification.request.identifier
        let reply = response.actionIdentifier == PushAction.reply.identifier
        Task { @MainActor in
            if reply { read.attachments = await PushReplies.stagedAttachments(for: requestID) }
            await PushReplies.shared.handle(read)
            completionHandler()
        }
    }
}

/// Settings → Devices and account deletion over the live coordinator.
@MainActor
final class LiveDeviceDirectory: SettingsDeviceDirectory {
    private weak var live: LiveCoordinator?

    init(live: LiveCoordinator) {
        self.live = live
    }

    var relayAvailable: Bool? { live?.relayAvailable }

    struct NotSignedIn: Error {}

    private static let presenceSuffix = " (presence)"

    /// The service's devices, a phone's link and presence ids folded into one row.
    func devices() async throws -> [SettingsDevice] {
        guard let live else { return [] }
        let all = try await live.myDevices()
        let own = live.ownDeviceIDs
        var out: [SettingsDevice] = []
        for device in all where device.kind == "mac" {
            out.append(SettingsDevice(ids: [device.deviceId], kind: .mac, name: device.name, online: device.online ?? false,
                                      lastSeenAt: device.lastSeenDate, addedAt: device.createdDate, isThisDevice: false, receivesNotifications: false,
                                      machineID: device.machineId, teamID: device.teamId))
        }
        let phones = all.filter { $0.kind == "phone" }
        let presence = phones.filter { $0.name.hasSuffix(Self.presenceSuffix) }
        for phone in phones where !phone.name.hasSuffix(Self.presenceSuffix) {
            let mine = own.contains(phone.deviceId)
            // The presence id that goes with this phone: our own, or the only one with its name in its team.
            let partners = presence.filter {
                mine ? own.contains($0.deviceId) : ($0.teamId == phone.teamId && $0.name == phone.name + Self.presenceSuffix)
            }
            let sameName = phones.filter { $0.name == phone.name && $0.teamId == phone.teamId }.count
            let ids = [phone.deviceId] + (partners.count == 1 && (mine || sameName == 1) ? [partners[0].deviceId] : [])
            out.append(SettingsDevice(ids: ids, kind: .phone, name: phone.name, online: nil, lastSeenAt: phone.lastSeenDate,
                                      addedAt: phone.createdDate, isThisDevice: mine, receivesNotifications: phone.push ?? false))
        }
        // The id last: Macs that share a name keep one order across loads.
        return out.sorted { ($0.kind == .mac ? 0 : 1, $0.isThisDevice ? 0 : 1, $0.name, $0.id) < ($1.kind == .mac ? 0 : 1, $1.isThisDevice ? 0 : 1, $1.name, $1.id) }
    }

    func remove(_ device: SettingsDevice) async throws {
        guard let live else { throw NotSignedIn() }
        do {
            for id in device.ids { try await live.removeDevice(id: id) }
        } catch {
            throw LiveAPI.removalMessage(for: error)
        }
    }

    func deleteAccountData() async throws {
        guard let live else { throw NotSignedIn() }
        try await live.deleteAccountData()
    }

    func removeThisPhoneFromMacs() async {
        await live?.removeThisPhoneFromMacs()
    }

    func openPairingCode(_ text: String) -> Bool {
        guard let live, let invite = PairInvite(text: text) else { return false }
        return live.accept(invite)
    }
}
#endif

#if DEBUG && os(iOS)
/// DEBUG mock mode only (Settings → Developer → Mock): Settings →
/// Devices over the sample store, so the removal UI can be exercised
/// and captured without a signed-in Mac. Compiled out of Production.
@MainActor
final class MockDeviceDirectory: SettingsDeviceDirectory {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    var relayAvailable: Bool? { nil }

    func devices() async throws -> [SettingsDevice] {
        store.teams.flatMap(\.macs).reduce(into: [SettingsDevice]()) { out, mac in
            guard !out.contains(where: { $0.id == mac.id }) else { return }
            out.append(SettingsDevice(ids: [mac.id], kind: .mac, name: mac.name, online: mac.isOnline, lastSeenAt: mac.lastSeenAt,
                                      isThisDevice: false, receivesNotifications: false))
        }
    }

    func remove(_ device: SettingsDevice) async throws {
        for id in device.ids { store.forgetMac(id) }
    }

    func deleteAccountData() async throws {}

    func removeThisPhoneFromMacs() async {}
}
#endif
