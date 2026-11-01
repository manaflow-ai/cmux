#if DEBUG && os(iOS) && targetEnvironment(simulator)
import CmuxMobileLive
import CmuxMobileNotifications
import Foundation
import OSLog
import UserNotifications

/// DEBUG, simulator only: `xcrun simctl push` never runs a Notification Service
/// Extension, so a sealed push (PR B) stays its generic banner there. With
/// `SIMCTL_CHILD_CMUX_MOBILE_DEV_SERVICE_PUSH=<file>` (an APNs body the real
/// Mac host and Worker produced), the app runs the extension's own code
/// (`ServicePush`) on it at launch and posts the result as a notification, so
/// the rig can exercise the opened banner, its buttons and their replies.
/// Release, Production and device builds compile none of it.
struct SimulatedServiceExtension {
    static let variable = "CMUX_MOBILE_DEV_SERVICE_PUSH"
    /// `SIMCTL_CHILD_CMUX_MOBILE_DEV_PUSH_TOKEN=1`: registers a stand-in APNs token (a
    /// simulator gets none), so the service records this phone's notification settings
    /// and the Mac learns which kinds it wants. Nothing is ever delivered to it.
    static let tokenVariable = "CMUX_MOBILE_DEV_PUSH_TOKEN"

    @MainActor static func registerStandInTokenIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment[tokenVariable] == "1" else { return }
        PushRegistration.shared.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
    }

    /// The value is a file path, or the APNs body itself (starting with `{`), which a UI
    /// test can pass in its launch environment without sharing a file with the app.
    static func deliverIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let value = environment[variable], !value.isEmpty,
              let data = value.hasPrefix("{") ? Data(value.utf8) : FileManager.default.contents(atPath: value) else { return }
        // A fresh simulator was never asked: ask first (a no-op once answered), so the push shows.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in post(data) }
    }

    private static func post(_ data: Data) {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let content = UNMutableNotificationContent()
        let aps = body["aps"] as? [String: Any]
        if let alert = aps?["alert"] as? [String: Any] {
            content.title = alert["title"] as? String ?? ""
            content.subtitle = alert["subtitle"] as? String ?? ""
            content.body = alert["body"] as? String ?? ""
        } else if let payload = PushPayload(userInfo: body) {
            // No alert given: the text the Worker writes for this payload (`PushBanner` matches its `alert`).
            let banner = PushBanner(payload: payload)
            content.title = banner.title
            content.subtitle = banner.subtitle ?? ""
            content.body = banner.body
        }
        // An unsealed push keeps the category APNs delivers it under, so its long look is the content extension's.
        if let category = aps?["category"] as? String { content.categoryIdentifier = category }
        content.userInfo = body.filter { $0.key != "aps" }
        let keys = PushKeys.current()
        let opened = ServicePush().opened(content, keys: keys) ?? ServicePush().inert(content, trust: keys?.trust()) ?? content
        let request = UNNotificationRequest(identifier: "dev-service-push-\(UUID().uuidString)", content: opened, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Logger(subsystem: "dev.cmux.mobile", category: "push").error("simulated service push: \(String(describing: error), privacy: .public)") }
        }
    }
}
#endif
