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
            sleep(2)
            attach(XCUIScreen.main.screenshot(), "banner-\(name)")
            note(springboard, "nc-\(name)")
            // The long look: a long press on the notification (Haptic Touch).
            cell.press(forDuration: 2.5)
            sleep(4)
            attach(XCUIScreen.main.screenshot(), "longlook-\(name)")
            note(springboard, "longlook-\(name)")
            if name == "light" {
                // Second way, once: press and hold at the cell's centre a little longer.
                XCUIDevice.shared.press(.home)
                sleep(2)
                let again = openNotificationCenter(springboard)
                sleep(2)
                let centre = again.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                centre.press(forDuration: 3.5, thenDragTo: centre)
                sleep(4)
                attach(XCUIScreen.main.screenshot(), "longlook2-\(name)")
                note(springboard, "longlook2-\(name)")
            }
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
        // The cmux notification's own platter. A stack (another app's notice on top) is
        // expanded first by tapping it, so the cmux one is its own cell.
        let match = NSPredicate(format: "label CONTAINS[c] %@", "Claude Code")
        let platter = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").matching(match).firstMatch
        if !platter.waitForExistence(timeout: 6) {
            let stack = springboard.buttons.matching(identifier: "ListCell").matching(NSPredicate(format: "label != ''")).firstMatch
            if stack.exists { stack.tap(); sleep(2) }
        }
        let cell = platter.waitForExistence(timeout: 6)
            ? platter : springboard.buttons.matching(identifier: "ListCell").matching(match).firstMatch
        note(springboard, "cell", extra: cell.debugDescription)
        if !cell.exists {
            attach(XCUIScreen.main.screenshot(), "no-notification")
            XCTFail("the permission notification is in Notification Center\n\(springboard.debugDescription)")
        }
        return cell
    }

    /// The element tree, kept with the screenshots.
    @MainActor
    private func note(_ app: XCUIApplication, _ name: String, extra: String = "") {
        let attachment = XCTAttachment(string: extra + "\n" + app.debugDescription)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
