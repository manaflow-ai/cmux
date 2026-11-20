import XCTest

/// Real cmux notifications on a simulator, for the onboarding's notifications page
/// (Aziz 2026-11-19: "use push notifications there then present a real example").
/// Three pushes in the Worker's APNs format (a finished task, a Chief message, a
/// permission request) go through the app's own service-extension code
/// (`SimulatedServiceExtension`), so iOS draws them exactly as on a phone. The test
/// attaches Notification Center with all three and the permission's long look, in
/// light and dark (`push~~…` attachments); the page's images are cropped from them.
final class OnboardingPushShotUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private static let mac = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    static func push(_ kind: String, agent: String, workspace: String, extra: [String: Any], category: String) -> String {
        var payload: [String: Any] = [
            "v": 2, "mac": mac, "macName": "Aziz's MacBook Pro", "kind": kind,
            "eventId": "onboarding-\(kind)", "agent": agent, "workspace": workspace,
            "postedAt": Int(Date().timeIntervalSince1970),
        ]
        payload.merge(extra) { $1 }
        let body: [String: Any] = ["aps": ["category": category, "mutable-content": 1, "thread-id": "onboarding-\(kind)"], "cmuxMobile": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Oldest first: Notification Center shows the last one on top.
    static let pushes: [String] = [
        push("chief", agent: "Chief", workspace: "Home",
             extra: ["conversationId": "home", "title": "Chief",
                     "body": "The nightly is green again. Two PRs are ready for you to try."],
             category: "CMUX_MOBILE_CHIEF"),
        push("completed", agent: "Codex", workspace: "api-server",
             extra: ["sessionId": "onboarding-codex", "title": "Finished: fix the failing auth tests",
                     "body": "2 tests fixed. The diff is ready to review."],
             category: "CMUX_MOBILE_COMPLETED"),
        push("permission", agent: "Claude Code", workspace: "cmux",
             extra: ["sessionId": "onboarding-claude", "permissionId": "onboarding-perm",
                     "title": "git push origin feat-onboarding",
                     "options": [["id": "allow-once", "label": "Allow once", "kind": "allow_once"],
                                 ["id": "allow-always", "label": "Always allow", "kind": "allow_always"],
                                 ["id": "deny", "label": "Deny", "kind": "reject_once"]]],
             category: "CMUX_MOBILE_PERMISSION"),
    ]

    @MainActor func testRealPushesDark() { capture(.dark) }
    @MainActor func testRealPushesLight() { capture(.light) }

    @MainActor
    private func capture(_ appearance: XCUIDevice.Appearance) {
        let look = appearance == .dark ? "dark" : "light"
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
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
            sleep(1)
        }
        XCUIDevice.shared.press(.home)
        sleep(1)
        // Notification Center from the top edge; a stack of cmux notices is expanded.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
        sleep(2)
        attach("push~~center-collapsed~~\(look)")
        let platter = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Claude Code")).firstMatch
        if platter.waitForExistence(timeout: 6) {
            platter.tap()   // a collapsed stack opens; an open list ignores a tap on the top platter's header
            sleep(2)
        }
        attach("push~~center~~\(look)")
        note(springboard, "center-\(look)")
        // The permission's long look: Allow once, Always allow, Deny.
        let top = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Claude Code")).firstMatch
        if top.waitForExistence(timeout: 6) {
            top.press(forDuration: 1.2)
            sleep(3)
            attach("push~~long-look~~\(look)")
            note(springboard, "long-look-\(look)")
        } else {
            XCTFail("no Claude Code notification in Notification Center\n\(springboard.debugDescription)")
        }
        XCUIDevice.shared.press(.home)
        sleep(1)
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
