import CmuxConversationCore
import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// This phone's per-conversation Chief settings: Hide Alerts and Send Read
/// Receipts. They belong to the phone, as in Messages, so they live in its
/// defaults, keyed by the owner's conversation id.
public struct ChiefPreferences: @unchecked Sendable {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ name: String, _ conversationID: String) -> String { "cmuxMobile.chief.\(conversationID).\(name)" }

    /// Hide Alerts: no notification for this conversation's messages.
    public func muted(_ conversationID: String) -> Bool {
        defaults.bool(forKey: key("muted", conversationID))
    }

    public func setMuted(_ muted: Bool, _ conversationID: String) {
        defaults.set(muted, forKey: key("muted", conversationID))
    }

    /// Send Read Receipts: whether reading here moves the read position the
    /// Mac (and Chief) see. On by default, as in Messages.
    public func sendsReadReceipts(_ conversationID: String) -> Bool {
        defaults.object(forKey: key("receipts", conversationID)) as? Bool ?? true
    }

    public func setSendsReadReceipts(_ on: Bool, _ conversationID: String) {
        defaults.set(on, forKey: key("receipts", conversationID))
    }

    /// Where this phone has read to with Send Read Receipts off (the Mac's
    /// cursor stays behind): kept, so a reconnect or relaunch does not bring
    /// the unread count back.
    public func readHere(_ conversationID: String) -> Int? {
        defaults.object(forKey: key("readHere", conversationID)) as? Int
    }

    public func setReadHere(_ seq: Int, _ conversationID: String) {
        defaults.set(seq, forKey: key("readHere", conversationID))
    }

    /// The newest message seen with the conversation open on this phone
    /// (Home's Needs You for an unseen question): kept, so a relaunch does not
    /// bring back every question already seen.
    public func seenMessageID(_ conversationID: String) -> String? {
        defaults.string(forKey: key("seen", conversationID))
    }

    public func setSeenMessageID(_ id: String?, _ conversationID: String) {
        defaults.set(id, forKey: key("seen", conversationID))
    }

    /// The newest engine report read from the Mac `macID` (its model,
    /// harness, effort and the models it offered), so Chief's settings show
    /// the model even while that Mac's Chief can't list its models.
    public func engineReport(macID: String) -> ChiefEngineReport? {
        guard let data = defaults.data(forKey: "cmuxMobile.chief.mac.\(macID).engine") else { return nil }
        return try? JSONDecoder().decode(ChiefEngineReport.self, from: data)
    }

    public func setEngineReport(_ report: ChiefEngineReport, macID: String) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        defaults.set(data, forKey: "cmuxMobile.chief.mac.\(macID).engine")
    }

    /// The list state the details page shows for `conversationID`.
    public func listState(_ conversationID: String) -> ConversationListState {
        ConversationListState(pinned: true, pinOrder: 0, muted: muted(conversationID),
                              sendReadReceipts: sendsReadReceipts(conversationID))
    }
}

/// Local notifications for Chief's messages: one per new message from Chief
/// while the Chief conversation is not on screen, unless Hide Alerts is on.
/// Chief reaches the phone only over the live link, so these come while the
/// app runs (in the foreground, or in the background before iOS suspends it).
@MainActor
public final class ChiefAlerts: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ChiefAlerts()

    /// False while the app is in the background, where an open Chief is not seen.
    private var appActive = true
    private var installed = false
    private var observers: [NSObjectProtocol] = []

    /// Shows Chief's alerts as banners while the app is in the foreground.
    /// Takes the delegate only when no one else has.
    public func install() {
        guard !installed, Self.canNotify else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        #if canImport(UIKit)
        let notifications = NotificationCenter.default
        observers = [
            notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ChiefAlerts.shared.appActive = false }
            },
            notifications.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ChiefAlerts.shared.appActive = true }
            },
        ]
        #endif
    }

    /// Asks for notification permission the first time the user writes to
    /// Chief, if the system has not asked yet: Chief's replies arrive as
    /// alerts. Setup asks only on builds that can receive pushes from the
    /// Macs, so on other builds this is where Chief's alerts get permission.
    public func requestPermissionIfUndetermined() {
        guard Self.canNotify, !askedThisSession else { return }
        askedThisSession = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
    }
    private var askedThisSession = false

    /// The notification center exists only for an app bundle (not a test runner).
    static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Posts an alert for `message` from Chief in `conversationID`.
    /// `visible`: that Chief's conversation is on screen (it shows the message itself).
    func notify(_ message: ConversationMessage, title: String, conversationID: String, macID: String? = nil,
                preferences: ChiefPreferences, visible: Bool) {
        guard Self.canNotify, !(visible && appActive), !preferences.muted(conversationID) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message.isUnsent ? String(localized: "Message unsent")
            : message.text.isEmpty && !message.attachments.isEmpty ? String(localized: "Attachment") : message.text
        content.sound = .default
        content.threadIdentifier = "chief.\(conversationID)"
        var userInfo: [String: String] = [Self.conversationKey: conversationID]
        if let macID { userInfo[Self.macKey] = macID }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: "chief.\(message.id)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            try? await center.add(request)
        }
    }

    nonisolated static let conversationKey = "cmuxMobile.chief.conversation"
    nonisolated static let macKey = "cmuxMobile.chief.mac"

    /// Where a tap on one of these alerts goes: Chief's conversation (kind
    /// `chief`, the shell's route), on its Mac when it has one. Nil for any
    /// other notification, and for a button other than the tap itself.
    public nonisolated static func route(userInfo: [AnyHashable: Any], actionIdentifier: String)
        -> (kind: String, mac: String?, conversationID: String)? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let conversation = userInfo[conversationKey] as? String else { return nil }
        return ("chief", userInfo[macKey] as? String, conversation)
    }

    /// Take back what is already delivered for a conversation: Hide Alerts
    /// turned on, or its messages were read (here or on the Mac).
    func clearDelivered(conversationID: String) {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.deliveredNotifications()
                // This app's own alerts, and the Macs' Chief pushes (`<mac>:chief:<conversation>`).
                .filter {
                    let thread = $0.request.content.threadIdentifier
                    return thread == "chief.\(conversationID)" || thread.hasSuffix(":chief:\(conversationID)")
                }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
