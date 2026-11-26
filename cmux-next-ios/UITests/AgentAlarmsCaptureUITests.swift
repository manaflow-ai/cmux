import XCTest

/// Agent Alarms (verify/agent-alarms.md), every state a person meets, as screenshots: the page
/// off and not asked, iOS's alarm permission prompt, on and allowed, every trigger, Test Alarm
/// ringing, the 30 second debounce holding a second alarm and then letting one through, each
/// push kind ringing from the extension's chain on a cold launch (cmux not running), a
/// repeated ask not ringing twice, a live Feed ask ringing and stopping when it is answered,
/// a Mac that drops ringing, and the Recent list, in light and dark. Pushes are synthetic
/// (unsealed, in the Worker's format) and go through `SimulatedServiceExtension`, which runs
/// the service extension's own code; nothing is sent anywhere.
final class AgentAlarmsCaptureUITests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var app = XCUIApplication()
    /// When the last alarm rang, to wait out the 30 s window between captures.
    var lastRang: Date?

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentAlarmsEveryState() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .light

        // 1. Notifications → Agent Alarms, off and not asked yet.
        launch(page: "notifications")
        let row = app.buttons["settings.notifications.agentAlarms"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Notifications shows the Agent Alarms row")
        shot("01-notifications-row-off")
        row.tap()
        let enabled = app.switches["settings.agentAlarms.enabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Not asked"].exists, "permission reads Not asked")
        shot("02-off-not-asked")

        // 2. Turning it on asks iOS; allow.
        flip(enabled)
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 15) {
            shot("03-permission-prompt")
            note(springboard, "permission-prompt")
            allow.tap()
        } else {
            shot("03-no-permission-prompt")
            note(springboard, "no-permission-prompt")
            XCTFail("iOS asks for alarm permission")
        }
        XCTAssertTrue(app.staticTexts["Allowed"].waitForExistence(timeout: 10), "permission reads Allowed")
        XCTAssertEqual(enabled.value as? String, "1")
        shot("04-on-allowed")

        // 3. Every trigger, Mac went offline turned on too.
        let macOffline = app.switches["settings.agentAlarms.trigger.macOffline"].firstMatch
        app.swipeUp()
        if macOffline.waitForExistence(timeout: 5) { flip(macOffline) }
        shot("05-triggers-all-on")
        app.swipeDown()

        // 4. Test Alarm rings.
        let test = app.buttons["settings.agentAlarms.test"].firstMatch
        if !test.isHittable { app.swipeUp() }
        test.tap()
        lastRang = Date()
        captureAlarm("06-test-alarm-ringing", stop: false)
        sleep(2)
        shot("06b-test-alarm-ringing-later")
        stopAlarm()

        // 5. A second alarm within 30 s is held.
        if !test.isHittable { app.swipeUp() }
        test.tap()
        sleep(2)
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentAlarms.recent.debounced"].waitForExistence(timeout: 5),
                      "Recent shows the held alarm")
        shot("07-debounced-held")
        note(springboard, "debounced-no-alarm")

        // 6. After the window: Ready.
        waitOutDebounce()
        shot("08-window-over-ready")

        // 7. Each push kind, cmux not running: a cold launch with the push, then Home.
        coldPush("09-push-permission", Self.push(kind: "permission", permission: "cap-perm-1", agent: "Claude Code"))
        coldPush("10-push-question", Self.push(kind: "question", permission: "cap-q-1", agent: "Codex"))
        coldPush("11-push-terminal-waiting", Self.push(kind: "terminal", state: "waiting", event: "cap-term-1", agent: "Claude Code"))
        coldPush("12-push-agent-failed", Self.push(kind: "failed", event: "cap-fail-1", agent: "Codex"))
        coldPush("13-push-terminal-failed", Self.push(kind: "terminal", state: "failed", event: "cap-term-fail-1", agent: "Claude Code"))
        // The same ask again, after the window: one alarm per event, so nothing rings.
        coldPush("14-push-same-ask-again-no-alarm", Self.push(kind: "permission", permission: "cap-perm-1", agent: "Claude Code"),
                 expectsAlarm: false)
        // A finished turn never rings.
        coldPush("15-push-finished-no-alarm", Self.push(kind: "completed", event: "cap-done-1", agent: "Claude Code"), expectsAlarm: false)

        // 8. Two asks 3 s apart, cmux in front: the first rings, the second is held.
        waitOutDebounce()
        relaunch(environment: ["CMUX_MOBILE_DEV_SERVICE_PUSH": Self.push(kind: "permission", permission: "cap-burst-1", agent: "Claude Code")],
                 page: "agentAlarms")
        lastRang = Date()
        captureAlarm("16-burst-first-rings", stop: true)
        relaunch(environment: ["CMUX_MOBILE_DEV_SERVICE_PUSH": Self.push(kind: "question", permission: "cap-burst-2", agent: "Codex")],
                 page: "agentAlarms")
        sleep(5)
        shot("17-burst-second-held")

        // 9. The live Feed: an ask arrives over the link and rings; answered on the Mac 10 s later, it stops.
        waitOutDebounce()
        relaunch(environment: ["CMUX_MOBILE_DEV_AGENT_ALARM_FEED": "permission", "CMUX_MOBILE_DEV_AGENT_ALARM_CLOSE": "10"], tab: "feed")
        sleep(6)
        lastRang = Date()
        shot("18-feed-ask-ringing")
        note(springboard, "feed-ask-ringing")
        sleep(10)
        shot("19-feed-ask-answered-alarm-stopped")
        note(springboard, "feed-ask-stopped")

        // 10. Each other Feed kind, cmux open.
        for kind in ["question", "needsInput", "failed"] {
            waitOutDebounce()
            relaunch(environment: ["CMUX_MOBILE_DEV_AGENT_ALARM_FEED": kind], tab: "feed")
            sleep(6)
            lastRang = Date()
            shot("20-feed-\(kind)-ringing")
            stopAlarm()
        }

        // 11. A connected Mac drops and stays unreachable (3 s grace in DEBUG, 60 s shipped).
        waitOutDebounce()
        relaunch(environment: ["CMUX_MOBILE_DEV_AGENT_ALARM_MAC_OFFLINE": "Mac mini"], tab: "home")
        sleep(10)
        lastRang = Date()
        shot("21-mac-offline-ringing")
        stopAlarm()

        // 12. The Recent list, light and dark.
        relaunch(environment: [:], page: "agentAlarms")
        app.swipeUp()
        sleep(1)
        shot("22-recent-light")
        app.swipeUp()
        sleep(1)
        shot("23-how-it-works-light")
        app.terminate()
        XCUIDevice.shared.appearance = .dark
        sleep(2)
        relaunch(environment: [:], page: "agentAlarms")
        shot("24-on-allowed-dark")
        app.swipeUp()
        sleep(1)
        shot("25-recent-dark")
        app.terminate()
        relaunch(environment: [:], page: "notifications")
        shot("26-notifications-row-on-dark")
        XCUIDevice.shared.appearance = .light
    }

    // MARK: Steps

    @MainActor
    private func launch(page: String? = nil, tab: String = "settings", environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", tab]
        if let page { app.launchArguments += ["-cmux-mobile-settings-page", page] }
        app.launch()
        // The push stand-in asks for notification permission once.
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    @MainActor
    private func relaunch(environment: [String: String], page: String? = nil, tab: String = "settings") {
        app.terminate()
        launch(page: page, tab: tab, environment: environment)
    }

    /// A cold launch that carries one push (the extension's chain runs on it), then Home: the
    /// alarm rings over the Home Screen, as it does with cmux in the background or closed.
    @MainActor
    private func coldPush(_ name: String, _ push: String, expectsAlarm: Bool = true) {
        waitOutDebounce()
        app.terminate()
        launch(tab: "home", environment: ["CMUX_MOBILE_DEV_SERVICE_PUSH": push])
        XCUIDevice.shared.press(.home)
        if expectsAlarm { lastRang = Date() }
        captureAlarm(name, stop: true)
    }

    /// The alarm as it shows, a few seconds after it was set, and the element tree beside it.
    @MainActor
    private func captureAlarm(_ name: String, stop: Bool) {
        sleep(4)
        shot(name)
        note(springboard, name)
        if stop { stopAlarm() }
    }

    /// Stops a ringing alarm with its own Stop control, when iOS shows one.
    @MainActor
    private func stopAlarm() {
        let stop = springboard.buttons.matching(NSPredicate(format: "label ==[c] 'Stop' OR identifier ==[c] 'Stop'")).firstMatch
        if stop.waitForExistence(timeout: 2), stop.isHittable { stop.tap() }
        sleep(1)
    }

    @MainActor
    private func waitOutDebounce() {
        guard let lastRang else { return }
        let left = 31 - Date().timeIntervalSince(lastRang)
        if left > 0 { Thread.sleep(forTimeInterval: left) }
    }

    /// A Toggle's switch, at its trailing edge (a tap on a List row's label doesn't flip it).
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    }

    /// An unsealed push in the Worker's format.
    static func push(kind: String, state: String? = nil, permission: String? = nil, event: String? = nil, agent: String) -> String {
        var payload: [String: Any] = [
            "v": 2, "mac": "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "macName": "Mac mini", "kind": kind,
            "agent": agent, "workspace": "cmux", "sessionId": "alarm-capture", "title": "rm -rf build && swift build",
            "postedAt": Int(Date().timeIntervalSince1970),
        ]
        if let state { payload["state"] = state }
        if let permission { payload["permissionId"] = permission }
        payload["eventId"] = event ?? permission ?? UUID().uuidString
        let category = switch kind {
        case "permission": "CMUX_MOBILE_PERMISSION"
        case "question": "CMUX_MOBILE_QUESTION_FORM"
        case "failed": "CMUX_MOBILE_FAILED"
        case "completed": "CMUX_MOBILE_COMPLETED"
        default: "CMUX_MOBILE_TERMINAL"
        }
        let body: [String: Any] = ["aps": ["category": category, "mutable-content": 1], "cmuxMobile": payload]
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Evidence

    @MainActor
    private func shot(_ name: String) {
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
