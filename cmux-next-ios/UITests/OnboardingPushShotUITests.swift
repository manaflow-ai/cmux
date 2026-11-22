import XCTest

/// Real cmux notifications on a simulator, for the onboarding's notifications page
/// (Aziz 2026-11-19: "use push notifications there then present a real example").
/// Three pushes (a Chief message, a finished task, a permission request) go through
/// the app's own simulated service extension (`SimulatedServiceExtension`) and iOS
/// draws them as on a phone. Each carries the Worker's own banner text in `aps.alert`
/// (`PushBanner(payload:)`: "Claude Code wants to act on <Mac>", "Codex finished",
/// "Chief") and no routable `cmuxMobile` payload: a mock sign-in publishes no push
/// account, so the service chain would withhold a routable one as another account's
/// (`ServicePush.withheld`), which is right and stays as it is. The test attaches
/// Notification Center in dark and light (`push~~…` attachments); the page's images
/// are cropped from them.
final class OnboardingPushShotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    static func push(thread: String, category: String, title: String, subtitle: String?, body: String) -> String {
        var alert: [String: Any] = ["title": title, "body": body]
        if let subtitle { alert["subtitle"] = subtitle }
        let payload: [String: Any] = ["aps": ["alert": alert, "category": category, "thread-id": thread]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Oldest first: Notification Center shows the last one on top.
    static let pushes: [String] = [
        push(thread: "onboarding-chief", category: "CMUX_MOBILE_CHIEF", title: "Chief", subtitle: nil,
             body: "The nightly is green again. Two PRs are ready for you to try."),
        push(thread: "onboarding-claude", category: "CMUX_MOBILE_COMPLETED", title: "Claude Code finished",
             subtitle: "api-server · MacBook Pro", body: "Fixed the 2 failing auth tests. The diff is ready to review."),
        push(thread: "onboarding-codex", category: "CMUX_MOBILE_PERMISSION", title: "Codex wants to act on MacBook Pro",
             subtitle: "cmux", body: "git push origin feat-onboarding"),
    ]

    /// One run posts the three pushes once, then captures Notification Center in
    /// dark and in light, so neither appearance shows the other's copies.
    @MainActor func testRealPushes() {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .dark
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        for (index, body) in Self.pushes.enumerated() {
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchEnvironment["CMUX_MOBILE_DEV_SERVICE_PUSH"] = body
            app.launchArguments = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
            app.launch()
            if index == 0 {
                let allow = springboard.alerts.buttons["Allow"].firstMatch
                if allow.waitForExistence(timeout: 12) { allow.tap() }
            }
            sleep(3)
            XCUIDevice.shared.press(.home)
            sleep(1)
            app.terminate()
            sleep(2)
        }
        for appearance in [XCUIDevice.Appearance.dark, .light] {
            let look = appearance == .dark ? "dark" : "light"
            XCUIDevice.shared.appearance = appearance
            XCUIDevice.shared.press(.home)
            sleep(2)
            // Notification Center from the top edge.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
            sleep(2)
            attach("push~~center-stacked~~\(look)")
            let top = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView")
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Codex wants")).firstMatch
            XCTAssertTrue(top.waitForExistence(timeout: 6), "the permission notification is in Notification Center\n\(springboard.debugDescription)")
            // The lock screen stacks them; a swipe up on the stack opens it into a list
            // (a tap would open a notification once the list is open).
            if top.exists {
                top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -3.5)))
            }
            sleep(2)
            attach("push~~center~~\(look)")
            note(springboard, "center-\(look)")
            XCUIDevice.shared.press(.home)
            sleep(2)
        }
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func note(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
