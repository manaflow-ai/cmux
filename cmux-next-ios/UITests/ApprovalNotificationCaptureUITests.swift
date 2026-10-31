import XCTest

/// Captures a permission notification as a person sees it outside the app: the
/// collapsed banner in Notification Center and its long look (the content
/// extension), in light and in dark. The push is synthetic: an unsealed APNs body
/// in the Worker's format, posted by the DEBUG simulator stand-in for the service
/// extension (`SimulatedServiceExtension`), which writes the Worker's banner text
/// for it (`PushBanner`). Visual evidence for verify/rich-push.md; it sends nothing.
final class ApprovalNotificationCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A Claude Code permission request from "Mac mini" in workspace "cmux".
    static func permissionPush(now: Date = Date()) -> String {
        let payload: [String: Any] = [
            "v": 2, "mac": "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "macName": "Mac mini", "kind": "permission",
            "eventId": "capture-1", "agent": "Claude Code", "workspace": "cmux", "sessionId": "capture-session",
            "permissionId": "capture-perm", "title": "rm -rf build && swift build -c release",
            "options": [
                ["id": "allow-once", "label": "Allow once", "kind": "allow_once"],
                ["id": "allow-always", "label": "Always allow", "kind": "allow_always"],
                ["id": "deny", "label": "Deny", "kind": "reject_once"],
            ],
            "postedAt": Int(now.timeIntervalSince1970),
        ]
        let body: [String: Any] = ["aps": ["category": "CMUX_MOBILE_PERMISSION", "mutable-content": 1], "cmuxMobile": payload]
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func testPermissionNotificationCapture() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_DEV_SERVICE_PUSH"] = Self.permissionPush()
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        app.launch()

        // The stand-in asks for notification permission first on a fresh simulator.
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(2)

        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            sleep(2)
            let name = appearance == .dark ? "dark" : "light"
            let cell = openNotificationCenter(springboard)
            attach(XCUIScreen.main.screenshot(), "banner-\(name)")
            cell.press(forDuration: 1.5)
            sleep(4)
            attach(XCUIScreen.main.screenshot(), "longlook-\(name)")
            add(XCTAttachment(string: springboard.debugDescription))
            // Close the long look and Notification Center.
            XCUIDevice.shared.press(.home)
            sleep(1)
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
    }

    /// Notification Center, pulled down from the top edge; returns the cmux permission notification.
    @MainActor
    private func openNotificationCenter(_ springboard: XCUIApplication) -> XCUIElement {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
        let down = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        top.press(forDuration: 0.1, thenDragTo: down)
        sleep(2)
        let cell = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rm -rf build")).firstMatch
        if !cell.waitForExistence(timeout: 10) {
            attach(XCUIScreen.main.screenshot(), "no-notification")
            XCTFail("the permission notification is in Notification Center\n\(springboard.debugDescription)")
        }
        return cell
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
