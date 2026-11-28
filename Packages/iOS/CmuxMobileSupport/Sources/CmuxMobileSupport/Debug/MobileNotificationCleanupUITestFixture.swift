#if DEBUG && targetEnvironment(simulator)
import Foundation
import OSLog
import UIKit
import UserNotifications

/// Seeds real Notification Center entries for the foreground-cleanup UI test.
/// Read state and removal still travel through the production shell and RPC.
@MainActor
public final class MobileNotificationCleanupUITestFixture {
    private let payloads: [[String: String]]
    private var scheduled = false

    public init() {
        let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_NOTIFICATION_CLEANUP"] ?? ""
        payloads = UITestConfig.mockDataEnabled
            ? (try? JSONDecoder().decode([[String: String]].self, from: Data(raw.utf8))) ?? []
            : []
    }

    public func prepare() async {
        guard !payloads.isEmpty else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge])
    }

    public func scheduleOnBackground() async {
        guard !payloads.isEmpty, !scheduled else { return }

        // Keep the async request additions alive after the test backgrounds
        // the app. Without this, the scene-phase Task can be suspended before
        // UserNotifications receives the requests, leaving Notification
        // Center empty and making the UI test meaningless.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "cmux.notification-cleanup-ui-fixture"
        )
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        await scheduleNotifications()
    }

    private func scheduleNotifications() async {
        guard !payloads.isEmpty, !scheduled else { return }
        scheduled = true
        for payload in payloads {
            guard let id = payload["requestID"], let title = payload["title"] else { continue }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Notification cleanup verification"
            content.threadIdentifier = id
            if let notificationID = payload["notificationId"] {
                content.userInfo = ["cmux": [
                    "notificationId": notificationID,
                    "macDeviceId": payload["macDeviceId"] ?? "ui-test-mac",
                    "macInstanceTag": payload["macInstanceTag"] ?? "dev",
                ]]
            }
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: id,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                ))
            } catch {
                Logger(subsystem: "dev.cmux.ios", category: "notification-cleanup-test")
                    .error("Failed to seed notification: \(error, privacy: .public)")
            }
        }
    }
}
#endif
