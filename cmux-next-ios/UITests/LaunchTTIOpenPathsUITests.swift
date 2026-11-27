import XCTest

/// Opening something inside a running app, timed by the app itself (the optimum ledger's
/// unmeasured iPhone rows, cmuxterm-hq docs/design/optimum-ledger.md):
///
/// - session switch (`ios-session-switch`, 16.7 ms): a workspace row tapped to its chat's
///   composer or its attached terminal on screen, again and again in one process
///   (`OpenMarks` `workspace_row_tap` to `chat_composer_ready` / `terminal_ready`). The first
///   open of the process is reported apart (`session_open_first`); the rest are switches.
/// - deep link (`ios-deep-link`, 250 ms): a cmux link handed to the running app (`app.open`,
///   as Messages or a QR code hands it) to the linked agent chat or terminal on screen
///   (`deep_link` to `chat_composer_ready` / `terminal_ready`; `route_opened` beside it).
/// - notification tap (`ios-notification-tap`, 250 ms): the app's banner for an agent's
///   request, tapped while the app is in front, to the named session's chat on screen
///   (`notification_tap` to `chat_composer_ready`; `route_opened` beside it).
/// - tab switch (`ios-tab-switch`, 8.3 ms): another tab's card tapped in the tab grid to the
///   first frame of its zoom, which draws that tab's last content (TabsKit `TabZoomDriver`'s
///   frame log, `CMUX_TABS_FRAME_LOG=1`, `firstFrameMs` of each zoom to a page).
///
/// Every span is the app's own clock (`CACurrentMediaTime` from the trigger), so the test
/// runner's taps and polls are not in it. Each test prints one `OPENPATH_SAMPLE {json}` per
/// open and one `OPENPATH {json}` per metric (n, p50, p95, max, misses); a miss is an open whose
/// end mark never came within the timeout, counted, never a zero. Named `LaunchTTI*` so the
/// sim script builds the optimized Demo app (with the DEBUG marks), as launch timings are.
///
/// Run idle and under duress on one simulator after one build:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=LaunchTTIOpenPathsUITests --arg duress=off --arg duress=heavy \
///       --artifact artifacts/ios-sim/evidence.zip
final class LaunchTTIOpenPathsUITests: XCTestCase {
    static let iterations = 8
    static let endKeys = ["chat_composer_ready", "terminal_ready"]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Session switch

    @MainActor
    func testSessionSwitch() throws {
        let app = LaunchTTIUITests.makeApp()
        app.launch()
        let rows = [LaunchTTIUITests.chatWorkspace, "workspace.row.ws-s1"]
        XCTAssertTrue(app.buttons[rows[0]].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        var first: [Double] = []
        var switches: [Double] = []
        var misses = 0
        for i in 0 ..< Self.iterations + 1 {
            let row = app.buttons[rows[i % rows.count]]
            guard row.waitForExistence(timeout: 15), row.isHittable else {
                XCTFail("row \(rows[i % rows.count]) not hittable, open \(i)\n\(app.debugDescription)")
                break
            }
            let before = Self.cycle(in: app)
            row.tap()
            if let span = waitSpan(app, after: before, trigger: "workspace_row_tap", flow: i == 0 ? "session_open_first" : "session_switch") {
                if i == 0 { first.append(span) } else { switches.append(span) }
            } else {
                misses += 1
            }
            // Settle, then back to the list (outside the timed span, which starts at the tap).
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            Self.back(app, to: app.buttons[rows[0]])
        }
        Self.report("session_open_first", first, misses: 0, target: 16.7)
        Self.report("session_switch", switches, misses: misses, target: 16.7)
        XCTAssertFalse(switches.isEmpty, "no session switch reached its end mark")
    }

    // MARK: Deep link

    @MainActor
    func testDeepLinkWarm() throws {
        let app = Self.mockApp(tab: "home")
        app.launch()
        Self.passTeamChooser(app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "shell\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // An agent link (ws-cmux's Claude tab) and a tab link (ws-ios's xcodebuild terminal),
        // in turn, so each link opens something not on screen already.
        let links = [
            ("agent", URL(string: "cmux://agent/claude/mock-t-claude?host=mac-studio")!),
            ("terminal_tab", URL(string: "cmux://tab/\(DeepLinkUITests.id("tab_", 48))")!),
        ]
        var spans: [Double] = []
        var routes: [Double] = []
        var misses = 0
        for i in 0 ..< Self.iterations {
            let (kind, url) = links[i % links.count]
            let before = Self.cycle(in: app)
            app.open(url)
            if let span = waitSpan(app, after: before, trigger: "deep_link", flow: "deep_link_\(kind)", routes: &routes) {
                spans.append(span)
            } else {
                misses += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        Self.report("deep_link", spans, misses: misses, target: 250)
        Self.report("deep_link_route_opened", routes, misses: 0, target: 250)
        XCTAssertFalse(spans.isEmpty, "no deep link reached its end mark")
    }

    // MARK: Notification tap

    /// An agent's permission request from the mock Mac's Claude session, as an unsealed APNs
    /// body (the DEBUG `SimulatedServiceExtension` posts it, as ApprovalNotificationCaptureUITests).
    static func permissionPush(_ n: Int) -> String {
        let payload: [String: Any] = [
            "v": 2, "mac": "mac-studio", "macName": "Mac Studio", "kind": "permission",
            "eventId": "openpath-\(n)-\(Int(Date().timeIntervalSince1970))", "agent": "Claude Code", "workspace": "cmux",
            "sessionId": "mock-t-claude", "permissionId": "openpath-perm-\(n)", "title": "swift build",
            "options": [
                ["id": "allow-once", "label": "Allow once", "kind": "allow_once"],
                ["id": "deny", "label": "Deny", "kind": "reject_once"],
            ],
            "postedAt": Int(Date().timeIntervalSince1970),
        ]
        let body: [String: Any] = ["aps": ["category": "CMUX_MOBILE_PERMISSION", "mutable-content": 1], "cmuxMobile": payload]
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    func testNotificationTapWarm() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = Self.mockApp(tab: "home")
        var spans: [Double] = []
        var routes: [Double] = []
        var misses = 0
        let runs = 4
        for i in 0 ..< runs {
            // Each launch posts one push (the stand-in reads it at launch); the app in front
            // shows a banner for a chat that is not open.
            app.terminate()
            app.launchEnvironment["CMUX_MOBILE_DEV_SERVICE_PUSH"] = Self.permissionPush(i)
            app.launch()
            let allow = springboard.alerts.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: i == 0 ? 10 : 2) { allow.tap() }
            Self.passTeamChooser(app)
            let match = NSPredicate(format: "label CONTAINS[c] %@", "Claude Code")
            let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").matching(match).firstMatch
            guard banner.waitForExistence(timeout: 20) else {
                print(#"OPENPATH_SAMPLE {"flow":"notification_tap","run":\#(i),"miss":"no banner"}"#)
                misses += 1
                continue
            }
            let before = Self.cycle(in: app)
            banner.tap()
            if let span = waitSpan(app, after: before, trigger: "notification_tap", flow: "notification_tap", routes: &routes) {
                spans.append(span)
            } else {
                misses += 1
            }
        }
        Self.report("notification_tap", spans, misses: misses, target: 250)
        Self.report("notification_tap_route_opened", routes, misses: 0, target: 250)
        XCTAssertFalse(spans.isEmpty, "no notification tap reached its end mark (misses: \(misses))\n\(app.debugDescription)")
    }

    // MARK: Tab switch

    @MainActor
    func testTabSwitch() throws {
        if let old = TabZoomFrameTimeUITests.logFile() { try? FileManager.default.removeItem(at: old) }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LAUNCH_MARKS"] = "1"
        app.launchEnvironment["CMUX_TABS_FRAME_LOG"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "9"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        Self.passTeamChooser(app)
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH[c] ', tab'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 60), "the tab grid's cards\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        var last = ""
        var opened = 0
        for i in 0 ..< Self.iterations {
            let labels = cards.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map(\.label)
            guard let label = labels.dropFirst(i % max(labels.count, 1)).first(where: { $0 != last }) ?? labels.first(where: { $0 != last }) else {
                XCTFail("no other hittable card, switch \(i)\n\(app.debugDescription)")
                break
            }
            app.buttons[label].firstMatch.tap()
            opened += 1
            last = label
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            guard tabsButton.waitForExistence(timeout: 10) else {
                XCTFail("the Tabs button on \(label)'s page\n\(app.debugDescription)")
                break
            }
            tabsButton.tap()
            XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "back on the grid, switch \(i)")
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        guard let file = TabZoomFrameTimeUITests.logFile(), let text = try? String(contentsOf: file, encoding: .utf8) else {
            return XCTFail("the app's Documents/tabs-zoom-frames.jsonl (CMUX_TABS_FRAME_LOG=1)")
        }
        let rows = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let toPage = rows.filter { ($0["toOverview"] as? Bool) == false }
        let firstFrames = toPage.compactMap { ($0["firstFrameMs"] as? NSNumber)?.doubleValue }
        let worst = toPage.compactMap { ($0["worstMs"] as? NSNumber)?.doubleValue }
        for (i, row) in toPage.enumerated() {
            let ms = (row["firstFrameMs"] as? NSNumber)?.doubleValue ?? -1
            print(String(format: #"OPENPATH_SAMPLE {"flow":"tab_switch","run":%ld,"first_frame_ms":%.2f}"#, i, ms))
        }
        Self.report("tab_switch", firstFrames, misses: max(0, opened - firstFrames.count), target: 8.3)
        Self.report("tab_switch_worst_frame", worst, misses: 0, target: 8.3)
        XCTAssertFalse(firstFrames.isEmpty, "no zoom to a page in the frame log\n\(text)")
    }

    // MARK: Marks

    @MainActor
    static func openMarks(in app: XCUIApplication) -> [String: Any] {
        let probe = app.staticTexts["debug.open-marks"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @MainActor
    static func cycle(in app: XCUIApplication) -> Int { (openMarks(in: app)["cycle"] as? NSNumber)?.intValue ?? 0 }

    /// Waits for a cycle after `before` started by `trigger` to reach an end mark; prints the
    /// sample and returns its span in ms (nil: a miss).
    @MainActor
    func waitSpan(_ app: XCUIApplication, after before: Int, trigger: String, flow: String, timeout: TimeInterval = 20) -> Double? {
        var routes: [Double] = []
        return waitSpan(app, after: before, trigger: trigger, flow: flow, routes: &routes, timeout: timeout)
    }

    @MainActor
    func waitSpan(_ app: XCUIApplication, after before: Int, trigger: String, flow: String,
                  routes: inout [Double], timeout: TimeInterval = 20) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        var marks: [String: Any] = [:]
        while Date() < deadline {
            marks = Self.openMarks(in: app)
            let cycle = (marks["cycle"] as? NSNumber)?.intValue ?? 0
            if cycle > before, marks["trigger"] as? String == trigger,
               Self.endKeys.contains(where: { marks[$0] != nil }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let end = Self.endKeys.compactMap { key in (marks[key] as? NSNumber).map { (key, $0.doubleValue) } }.min { $0.1 < $1.1 }
        let cycle = (marks["cycle"] as? NSNumber)?.intValue ?? 0
        let body = marks.sorted { $0.key < $1.key }.map { key, value in
            value is String ? "\"\(key)\":\"\(value)\"" : "\"\(key)\":\(value)"
        }.joined(separator: ",")
        guard cycle > before, marks["trigger"] as? String == trigger, let end else {
            print(#"OPENPATH_SAMPLE {"flow":"\#(flow)","miss":true,\#(body)}"#)
            return nil
        }
        if let route = (marks["route_opened"] as? NSNumber)?.doubleValue { routes.append(route) }
        print(#"OPENPATH_SAMPLE {"flow":"\#(flow)","end":"\#(end.0)","span_ms":\#(String(format: "%.2f", end.1)),\#(body)}"#)
        return end.1
    }

    /// One metric's line: n, p50, p95 (nearest rank), max, misses and the ledger's optimum.
    @MainActor
    static func report(_ metric: String, _ values: [Double], misses: Int, target: Double) {
        let sorted = values.sorted()
        func rank(_ p: Double) -> String {
            guard !sorted.isEmpty else { return "null" }
            let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
            return String(format: "%.2f", sorted[index])
        }
        let line = #"OPENPATH {"metric":"\#(metric)","n":\#(sorted.count),"p50":\#(rank(0.5)),"p95":\#(rank(0.95)),"max":\#(sorted.last.map { String(format: "%.2f", $0) } ?? "null"),"misses":\#(misses),"optimum_ms":\#(target)}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "openpath-\(metric)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "openpath-\(metric)") { $0.add(attachment) }
    }

    // MARK: App

    @MainActor
    static func mockApp(tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LAUNCH_MARKS"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", tab, "-cmux-mobile-no-restore",
                                "-cmux-mobile-term-no-intro"]
        return app
    }

    /// First run of mock data: pick the team whose Mac holds the workspaces.
    @MainActor
    static func passTeamChooser(_ app: XCUIApplication) {
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 3), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
    }

    /// Back to the list: the top bar's Back, else an edge swipe.
    @MainActor
    static func back(_ app: XCUIApplication, to row: XCUIElement) {
        for _ in 0 ..< 3 where !(row.exists && row.isHittable) {
            let back = app.buttons["Back"].firstMatch
            if back.exists, back.isHittable {
                back.tap()
            } else {
                let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            }
            _ = row.waitForExistence(timeout: 3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }
}
