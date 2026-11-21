import XCTest

/// Launch to first interaction on the iPhone, from the app's own marks
/// (`LaunchMarks`, `cmux-next-ios/design/launch-tti.md`): a Workspaces list of
/// 150 workspaces (the list rig in mock mode), then
///
/// - chat open: tap an agent workspace, until its composer is on screen
///   (`workspace_row_tap` to `chat_composer_ready`), and
/// - terminal input: tap a terminal workspace, type one key, until its echo is
///   presented (`workspace_row_tap` to `terminal_ready`, `terminal_key_sent` to
///   `terminal_echo_presented`).
///
/// Each iteration prints one line, `LAUNCHTTI {json}`: the flow, `warm` or
/// `cold`, and every mark in ms since the process started. The derived
/// `tti_ms` adds the app's own spans only (launch to the list's first frame,
/// tap to ready, key to echo), so the test runner's own delays between taps
/// are not in it.
///
/// - `LaunchTTIUITests` (warm): the app is terminated and launched again, 10 times
///   per flow, on a simulator that has run it before (the OS's caches warm).
/// - `LaunchTTIColdUITests` (cold): one launch per test, the first since the
///   simulator booted; `cmux-next-ios-sim.sh` runs a suite whose name ends in
///   `ColdUITests` once per fresh boot, `CMUX_LAUNCH_COLD_RUNS` (10) times.
///
/// Run on the fleet:
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=LaunchTTIUITests,LaunchTTIColdUITests --artifact artifacts/ios-sim/evidence.zip
class LaunchTTIUITests: XCTestCase {
    enum Flow: String { case chat, terminal }

    /// Workspaces in the list (the rig's `ws-s0` ... `ws-s149`).
    static let workspaceCount = 150
    /// `ws-s0` is an agent workspace waiting on the person: it opens on its chat.
    static let chatWorkspace = "workspace.row.ws-s0"
    /// `ws-s2` copies the mock `cmux-next-ios` workspace: its first tab is a terminal.
    static let terminalWorkspace = "workspace.row.ws-s2"
    static let warmIterations = 10

    var phase: String { "warm" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testChatOpenWarm() throws { try warm(.chat) }
    @MainActor func testTerminalInputWarm() throws { try warm(.terminal) }

    @MainActor
    private func warm(_ flow: Flow) throws {
        let app = Self.makeApp()
        // One unmeasured launch: the app's caches and the OS's warm.
        app.launch()
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        var results: [[String: Double]] = []
        for _ in 0 ..< Self.warmIterations {
            app.terminate()
            app.launch()
            results.append(try run(flow, app: app))
        }
        for key in ["tti_ms", "list_ms", "open_ms", "echo_ms"] {
            let values = results.compactMap { $0[key] }.sorted()
            guard !values.isEmpty else { continue }
            print(#"LAUNCHTTI_SUMMARY {"flow":"\#(flow.rawValue)","phase":"\#(phase)","metric":"\#(key)","n":\#(values.count),"p50":\#(Self.round(values[values.count / 2])),"min":\#(Self.round(values[0])),"max":\#(Self.round(values[values.count - 1]))}"#)
        }
    }

    /// One flow on a launched app: the marks, printed and returned with the spans.
    @MainActor
    func run(_ flow: Flow, app: XCUIApplication) throws -> [String: Double] {
        let row = app.buttons[flow == .chat ? Self.chatWorkspace : Self.terminalWorkspace]
        // The stress list replaces the mock one: wait for its first row, then the list's frame mark
        // (taken only by a seeded row, `ListStressSettings.countsListFrame`).
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        XCTAssertTrue(waitForMark("workspaces_list_frame", in: app), "the list's first frame mark")
        // The terminal workspace sits below the ones that need the person: scroll to it
        // (outside the app's timed spans, which start at the tap).
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
        switch flow {
        case .chat:
            XCTAssertTrue(waitForMark("chat_composer_ready", in: app), "the chat composer's mark\n\(app.debugDescription)")
        case .terminal:
            let field = app.textViews["terminal.composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
            XCTAssertTrue(waitForMark("terminal_ready", in: app), "the terminal's attached frame mark")
            field.tap()
            // `~`: probe a printable byte (the prompt, already drawn at terminal_ready, has one too).
            field.typeText("~")
            app.buttons["terminal.composer.send"].tap()
            XCTAssertTrue(waitForMark("terminal_echo_presented", in: app), "the echo's mark\n\(app.debugDescription)")
        }
        var marks = Self.marks(in: app)
        if let list = marks["workspaces_list_frame"] { marks["list_ms"] = list }
        if let tap = marks["workspace_row_tap"] {
            let ready = flow == .chat ? marks["chat_composer_ready"] : marks["terminal_ready"]
            if let ready { marks["open_ms"] = ready - tap }
        }
        if let sent = marks["terminal_key_sent"], let echo = marks["terminal_echo_presented"] { marks["echo_ms"] = echo - sent }
        if let list = marks["list_ms"], let open = marks["open_ms"] {
            marks["tti_ms"] = list + open + (flow == .terminal ? (marks["echo_ms"] ?? 0) : 0)
        }
        let body = marks.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\(Self.round($0.value))" }.joined(separator: ",")
        let sample = #"LAUNCHTTI {"flow":"\#(flow.rawValue)","phase":"\#(phase)","workspaces":\#(Self.workspaceCount),\#(body)}"#
        print(sample)
        // Test-runner stdout is not always available through xcresulttool's
        // console export. Keep the sample even when the test succeeds.
        let attachment = XCTAttachment(string: sample)
        attachment.name = "launch-tti"
        attachment.lifetime = .keepAlways
        add(attachment)
        return marks
    }

    // MARK: Marks

    @MainActor
    func waitForMark(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.marks(in: app)[name] != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    @MainActor
    static func marks(in app: XCUIApplication) -> [String: Double] {
        let probe = app.staticTexts["debug.launch-marks"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return object
    }

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

    static func round(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The cold half: each test is one launch, the first since the simulator booted
/// (the script reboots it before each run of this suite's tests).
final class LaunchTTIColdUITests: LaunchTTIUITests {
    override var phase: String { "cold" }

    @MainActor override func testChatOpenWarm() throws { throw XCTSkip("warm runs in LaunchTTIUITests") }
    @MainActor override func testTerminalInputWarm() throws { throw XCTSkip("warm runs in LaunchTTIUITests") }

    @MainActor func testChatOpenCold() throws { try cold(.chat) }
    @MainActor func testTerminalInputCold() throws { try cold(.terminal) }

    @MainActor
    private func cold(_ flow: Flow) throws {
        let app = Self.makeApp()
        app.launch()
        _ = try run(flow, app: app)
    }
}
