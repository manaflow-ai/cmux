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

    static func deliverIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[variable], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let content = UNMutableNotificationContent()
        if let alert = (body["aps"] as? [String: Any])?["alert"] as? [String: Any] {
            content.title = alert["title"] as? String ?? ""
            content.body = alert["body"] as? String ?? ""
        }
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
