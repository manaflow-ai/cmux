import XCTest

/// Resume after an app switch (Leo, 2026-11-22: "me swiping up to go to another app then back
/// to the ios cmux internal app... there's lag when coming back. lag to interaction."):
/// the app open on a terminal (or an agent chat) in mock mode, then per run: Home, away N
/// seconds, `activate()`, and
///
/// - first content: ms from the app's `willEnterForeground` to the first frame a terminal
///   presented attached to its session (`ResumeMarks` `terminal_frame`, the app's monotonic
///   clock); for chat, the wall time from `activate()` returning to the composer hittable;
/// - first input: a tap on the composer and a typed key that the session took
///   (`terminal_key_sent`, ms since `willEnterForeground`; it includes the runner's own tap and
///   typing, so it is an upper bound); for chat, wall time from `activate()` to the typed key
///   in the field;
/// - reconnect: a terminal frame drawn detached (`terminal_detached`) or a "Reconnecting"
///   label seen after the return.
///
/// Each run prints `RESUME {json}`; each away time prints `RESUME_SUMMARY {json}` (p50, p95).
///
/// Run on the fleet:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ResumeFromSwitchUITests --artifact artifacts/ios-sim/evidence.zip
final class ResumeFromSwitchUITests: XCTestCase {
    static let workspaceCount = 150
    static let chatWorkspace = "workspace.row.ws-s0"
    static let terminalWorkspace = "workspace.row.ws-s2"

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testTerminalAway1and5() throws { try terminal(aways: [(1, 20), (5, 20)]) }
    @MainActor func testTerminalAway30() throws { try terminal(aways: [(30, 20)]) }
    @MainActor func testTerminalAway300() throws { try terminal(aways: [(300, 3)]) }
    @MainActor func testChatAway1and5() throws { try chat(aways: [(1, 20), (5, 20)]) }

    // MARK: Terminal

    @MainActor
    private func terminal(aways: [(TimeInterval, Int)]) throws {
        let app = Self.makeApp()
        app.launch()
        open(Self.terminalWorkspace, in: app)
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        // One unmeasured key and send: the terminal is attached and echoing before the first switch.
        field.tap()
        field.typeText("~")
        app.buttons["terminal.composer.send"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for (away, runs) in aways {
            var rows: [[String: Double]] = []
            for index in 0 ..< runs {
                rows.append(terminalRun(app, away: away, index: index))
            }
            summarize("terminal", away: away, rows: rows)
        }
    }

    @MainActor
    private func terminalRun(_ app: XCUIApplication, away: TimeInterval, index: Int) -> [String: Double] {
        let before = Self.marks(app)["cycle"] ?? 0
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(away))
        let start = Date()
        app.activate()
        var row: [String: Double] = ["activate_wall_ms": Date().timeIntervalSince(start) * 1000]
        var reconnectLabel = reconnectingShown(app)
        // The terminal's attached frame after the return (or give up after 10 s).
        let marks = waitMarks(app, cycle: before + 1, timeout: 10) { $0["terminal_frame"] != nil }
        reconnectLabel = reconnectLabel || reconnectingShown(app)
        let field = app.textViews["terminal.composer.field"]
        let tapStart = Date()
        field.tap()
        row["tap_wall_ms"] = Date().timeIntervalSince(tapStart) * 1000
        field.typeText(["q", "z", "#", "%", "~"][index % 5])
        app.buttons["terminal.composer.send"].tap()
        let after = waitMarks(app, cycle: before + 1, timeout: 10) { $0["terminal_key_sent"] != nil }
        row["input_wall_ms"] = Date().timeIntervalSince(start) * 1000
        for (key, value) in after.merging(marks, uniquingKeysWith: { new, _ in new }) { row[key] = value }
        row["reconnect"] = (after["terminal_detached"] != nil || reconnectLabel) ? 1 : 0
        emit("terminal", away: away, row: row)
        return row
    }

    // MARK: Chat

    @MainActor
    private func chat(aways: [(TimeInterval, Int)]) throws {
        let app = Self.makeApp()
        app.launch()
        open(Self.chatWorkspace, in: app)
        XCTAssertTrue(openChatField(app, timeout: 30), "the chat composer\n\(app.debugDescription)")
        for (away, runs) in aways {
            var rows: [[String: Double]] = []
            for index in 0 ..< runs {
                let before = Self.marks(app)["cycle"] ?? 0
                XCUIDevice.shared.press(.home)
                RunLoop.current.run(until: Date().addingTimeInterval(away))
                let start = Date()
                app.activate()
                var row: [String: Double] = ["activate_wall_ms": Date().timeIntervalSince(start) * 1000]
                var reconnectLabel = reconnectingShown(app)
                let field = app.textViews["chat.composer.field"]
                let reply = app.buttons["Reply to Claude"].firstMatch
                let deadline = Date().addingTimeInterval(10)
                while !(field.exists && field.isHittable) && !(reply.exists && reply.isHittable), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                row["content_wall_ms"] = Date().timeIntervalSince(start) * 1000
                reconnectLabel = reconnectLabel || reconnectingShown(app)
                if openChatField(app, timeout: 10) {
                    field.tap()
                    let text = "r\(index)"
                    field.typeText(text)
                    let typed = Date().addingTimeInterval(5)
                    while !((field.value as? String) ?? "").contains(text), Date() < typed {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    }
                    row["input_wall_ms"] = Date().timeIntervalSince(start) * 1000
                    // Clear what was typed so the field stays one line.
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
                }
                for (key, value) in waitMarks(app, cycle: before + 1, timeout: 2, { $0["frame"] != nil }) { row[key] = value }
                row["reconnect"] = reconnectLabel ? 1 : 0
                emit("chat", away: away, row: row)
                rows.append(row)
            }
            summarize("chat", away: away, rows: rows)
        }
    }

    @MainActor
    private func openChatField(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let field = app.textViews["chat.composer.field"]
        let reply = app.buttons["Reply to Claude"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !field.exists, Date() < deadline {
            if reply.exists, reply.isHittable { reply.tap() }
            _ = field.waitForExistence(timeout: 0.5)
        }
        return field.exists
    }

    // MARK: Helpers

    @MainActor
    static func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LAUNCH_MARKS"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(workspaceCount)
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-term-no-intro"]
        return app
    }

    @MainActor
    private func open(_ id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    @MainActor
    private func reconnectingShown(_ app: XCUIApplication) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Reconnecting'")).firstMatch.exists
    }

    @MainActor
    static func marks(_ app: XCUIApplication) -> [String: Double] {
        let probe = app.staticTexts["debug.resume-marks"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return object
    }

    @MainActor
    private func waitMarks(_ app: XCUIApplication, cycle: Double, timeout: TimeInterval,
                           _ done: ([String: Double]) -> Bool) -> [String: Double] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Double] = [:]
        while Date() < deadline {
            let marks = Self.marks(app)
            if marks["cycle"] == cycle {
                last = marks
                if done(marks) { return marks }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return last
    }

    private func emit(_ flow: String, away: TimeInterval, row: [String: Double]) {
        let body = row.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\(String(format: "%.1f", $0.value))" }.joined(separator: ",")
        let line = #"RESUME {"flow":"\#(flow)","away_s":\#(Int(away)),\#(body)}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "resume-\(flow)-\(Int(away))s"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func summarize(_ flow: String, away: TimeInterval, rows: [[String: Double]]) {
        let keys = Set(rows.flatMap(\.keys)).subtracting(["cycle"]).sorted()
        var parts: [String] = []
        for key in keys {
            let values = rows.compactMap { $0[key] }.sorted()
            guard !values.isEmpty else { continue }
            let p50 = values[values.count / 2]
            let p95 = values[min(values.count - 1, Int((Double(values.count) * 0.95).rounded(.up)) - 1)]
            parts.append(String(format: "\"%@\":{\"n\":%d,\"p50\":%.1f,\"p95\":%.1f,\"max\":%.1f}", key, values.count, p50, p95, values[values.count - 1]))
        }
        let line = #"RESUME_SUMMARY {"flow":"\#(flow)","away_s":\#(Int(away)),"runs":\#(rows.count),\#(parts.joined(separator: ","))}"#
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "resume-summary-\(flow)-\(Int(away))s"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
