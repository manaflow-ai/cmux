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
    func testPermissionNotificationCaptureDark() throws { try capture(.dark) }

    @MainActor
    func testPermissionNotificationCaptureLight() throws { try capture(.light) }

    /// One appearance per test: set before the app launches, so iOS and the extension both draw in it.
    @MainActor
    private func capture(_ appearance: XCUIDevice.Appearance) throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
        sleep(3)
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

        do {
            let name = appearance == .dark ? "dark" : "light"
            _ = openNotificationCenter(springboard)
            sleep(2)
            attach(XCUIScreen.main.screenshot(), "banner-\(name)")
            XCUIDevice.shared.press(.home)
            sleep(2)
            // The long look from a banner: the app in front posts the push again (it presents
            // banners for a chat that is not open), and the banner is pulled down.
            app.terminate()
            app.launchEnvironment["CMUX_MOBILE_DEV_SERVICE_PUSH"] = Self.permissionPush()
            app.launch()
            let match = NSPredicate(format: "label CONTAINS[c] %@", "Claude Code")
            let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").matching(match).firstMatch
            guard banner.waitForExistence(timeout: 20) else {
                attach(XCUIScreen.main.screenshot(), "no-banner-\(name)")
                note(springboard, "no-banner-\(name)")
                XCTFail("the permission banner shows while the app is in front\n\(springboard.debugDescription)")
                return
            }
            let from = banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 6.0))
            from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            // The long look is the approval card (ApprovalCardView), not the plain view.
            let card = springboard.descendants(matching: .any).matching(identifier: "cmux.push.approval")
                .matching(NSPredicate(format: "label CONTAINS %@", "wants to act on Mac mini")).firstMatch
            let opened = card.waitForExistence(timeout: 10)
            sleep(2)
            attach(XCUIScreen.main.screenshot(), "longlook-\(name)")
            note(springboard, "longlook-\(name)")
            XCTAssertTrue(opened, "the long look shows the approval card\n\(springboard.debugDescription)")
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
