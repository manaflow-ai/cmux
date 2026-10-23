#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileSettings
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

/// What a push from the Mac points at (PROTOCOL.md `POST /v1/devices/:id/notify`,
/// the payload's `mobile` object).
public struct NotificationRoute: Equatable, Sendable {
    public var kind: String
    public var mac: String?
    public var sessionID: String?
    public var workspaceID: String?
    public var tabID: String?

    /// Reads `userInfo["cmuxMobile"]`; nil for anything else.
    init?(userInfo: [AnyHashable: Any]) {
        guard let mobile = userInfo["cmuxMobile"] as? [String: Any], let kind = mobile["kind"] as? String else { return nil }
        self.kind = kind
        mac = mobile["mac"] as? String
        sessionID = mobile["sessionId"] as? String
        workspaceID = mobile["workspaceId"] as? String
        tabID = mobile["tabId"] as? String
    }
}

/// Hands notification taps to the shell, and asks it whether a notification's
/// tab is already on screen (then no banner shows).
@MainActor
@Observable
public final class NotificationRouter {
    public static let shared = NotificationRouter()

    /// A tapped notification the shell has not opened yet.
    public var pending: NotificationRoute?
    /// Set by the shell: whether this route's tab is what the user is looking at.
    @ObservationIgnored var isShowing: (NotificationRoute) -> Bool = { _ in false }

    init() {}
}

/// The app delegate: remote-notification registration and notification
/// presentation and taps. Notification permission is asked in setup (or
/// Settings → Notifications); once granted, every launch registers so the
/// token stays current.
@MainActor
public final class CmuxMobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let route = NotificationRoute(userInfo: notification.request.content.userInfo)
        let showing = await MainActor.run { route.map { NotificationRouter.shared.isShowing($0) } ?? false }
        return showing ? [] : [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { NotificationRouter.shared.pending = route }
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
