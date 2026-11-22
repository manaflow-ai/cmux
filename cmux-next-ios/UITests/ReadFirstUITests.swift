import XCTest

/// Time to readable (R1) per tap, with no Mac reachable: from the tap to the first frame with real
/// content, from the app's own marks (`LaunchMarks.rearm(tap:)` and `firstContent(_:cached:)`,
/// `<surface>_first_content_cached` / `_live`). R2 is the tap to the first frame drawn from a
/// reply (`_live`); in mock mode the mock service, in process, stands in for the Mac.
///
/// Taps (`READFIRST {json}`, one line per run: tap, phase, r1_ms, r2_ms, the winning mark, and
/// every mark):
/// - `cold_launch`: process start to the first content (the Workspaces list rig, 150 rows)
/// - `warm_foreground`: back from the background to the first frame of the page kept on screen
/// - `open_chat`: a workspace row's tap to its chat's first content (`ws-s0`, an agent chat)
/// - `open_terminal`: a row's tap to its terminal's first content (`ws-s2`)
/// - `switch_session`: with a chat opened and left, the tap on another workspace (the terminal)
///
/// The app runs in mock mode with no backend at all (`CMUX_MOBILE_MOCK_AUTH=1`, no API base): the
/// link is cut by construction, so anything drawn comes from the phone. The disk caches (kept
/// transcripts, terminal frames, Home rows, last-known workspaces) mark `_cached`; the mock's
/// in-process data marks `_live`. R1 is the earlier of the two either way.
///
/// - `ReadFirstUITests` (warm): `iterations` runs per tap; the app is relaunched for each (the OS's
///   caches warm), except `warm_foreground`, which backgrounds one process.
/// - `ReadFirstColdUITests` (cold): one run per test, the first launch since the simulator booted
///   (`cmux-next-ios-sim.sh` reboots before each, `coldruns=N` times).
///
/// Run on the fleet (or through `scripts/measure/ios-network-conditions.sh leg=sim`):
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=ReadFirstUITests,ReadFirstColdUITests --arg coldruns=20 \
///       --artifact artifacts/ios-sim/evidence.zip
class ReadFirstUITests: XCTestCase {
    enum Tap: String { case coldLaunch = "cold_launch", warmForeground = "warm_foreground", openChat = "open_chat",
                            openTerminal = "open_terminal", switchSession = "switch_session" }

    static let iterations = 20
    static let chatWorkspace = LaunchTTIUITests.chatWorkspace
    static let terminalWorkspace = LaunchTTIUITests.terminalWorkspace
    /// How long a run waits for content before it counts as a miss (`r1_ms: null`).
    static let bound: TimeInterval = 20

    var phase: String { "warm" }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testColdLaunchWarm() throws { try warm(.coldLaunch) }
    @MainActor func testWarmForegroundWarm() throws { try warm(.warmForeground) }
    @MainActor func testOpenChatWarm() throws { try warm(.openChat) }
    @MainActor func testOpenTerminalWarm() throws { try warm(.openTerminal) }
    @MainActor func testSwitchSessionWarm() throws { try warm(.switchSession) }

    @MainActor
    private func warm(_ tap: Tap) throws {
        let app = LaunchTTIUITests.makeApp()
        // One unmeasured launch: the app's caches and the OS's warm.
        app.launch()
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        for _ in 0 ..< Self.iterations {
            if tap != .warmForeground {
                app.terminate()
                app.launch()
            }
            try run(tap, app: app)
        }
    }

    /// One run of `tap` on a launched app: its marks, printed as one READFIRST line.
    @MainActor
    func run(_ tap: Tap, app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 60), "the stress list\n\(app.debugDescription)")
        var tapMark = "tap_launch"
        var surfaces = ["workspaces", "home", "chats_list"]
        switch tap {
        case .coldLaunch:
            break
        case .warmForeground:
            // The list drawn before the first background (later runs return to the same page).
            if LaunchTTIUITests.marks(in: app)["tap_foreground"] == nil {
                _ = waitForContent(["workspaces"], after: "tap_launch", in: app)
            }
            XCUIDevice.shared.press(.home)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            app.activate()
            tapMark = "tap_foreground"
            surfaces = ["shown"]
        case .openChat:
            open(Self.chatWorkspace, in: app)
            tapMark = "tap_workspace_row"
            surfaces = ["chat"]
        case .openTerminal:
            open(Self.terminalWorkspace, in: app)
            tapMark = "tap_workspace_row"
            surfaces = ["terminal"]
        case .switchSession:
            open(Self.chatWorkspace, in: app)
            _ = waitForContent(["chat"], after: "tap_workspace_row", in: app)
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 10) { back.tap() } else { app.swipeRight() }
            XCTAssertTrue(app.buttons[Self.chatWorkspace].waitForExistence(timeout: 30), "back on the list\n\(app.debugDescription)")
            open(Self.terminalWorkspace, in: app)
            tapMark = "tap_workspace_row"
            surfaces = ["terminal"]
        }
        let marks = waitForContent(surfaces, after: tapMark, in: app)
        let start = tap == .coldLaunch ? 0 : marks[tapMark]
        let content = surfaces.flatMap { ["\($0)_first_content_cached", "\($0)_first_content_live"] }
            .compactMap { name in marks[name].map { (name, $0) } }
            .filter { start != nil && $0.1 >= start! }
        let first = content.min { $0.1 < $1.1 }
        let live = content.filter { $0.0.hasSuffix("_live") }.map(\.1).min()
        let r1 = first.flatMap { item in start.map { item.1 - $0 } }
        let r2 = live.flatMap { value in start.map { value - $0 } }
        let body = marks.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\(Self.round($0.value))" }.joined(separator: ",")
        let sample = #"READFIRST {"tap":"\#(tap.rawValue)","phase":"\#(phase)","r1_ms":\#(r1.map(Self.round) ?? "null"),"r2_ms":\#(r2.map(Self.round) ?? "null"),"first":"\#(first?.0 ?? "")","marks":{\#(body)}}"#
        print(sample)
        let attachment = XCTAttachment(string: sample)
        attachment.name = "read-first"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps a workspace row (scrolled to first, outside the timed span, which starts at the tap).
    @MainActor
    private func open(_ identifier: String, in app: XCUIApplication) {
        let row = app.buttons[identifier]
        for _ in 0 ..< 12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists && row.isHittable, "\(row) in the list\n\(app.debugDescription)")
        row.tap()
    }

    /// The marks once one of `surfaces` drew content after `tap` (or the bound passed).
    @MainActor
    private func waitForContent(_ surfaces: [String], after tap: String, in app: XCUIApplication) -> [String: Double] {
        let deadline = Date().addingTimeInterval(Self.bound)
        var marks: [String: Double] = [:]
        while Date() < deadline {
            marks = LaunchTTIUITests.marks(in: app)
            let start = tap == "tap_launch" ? 0 : marks[tap]
            if let start, surfaces.contains(where: { surface in
                ["cached", "live"].contains { (marks["\(surface)_first_content_\($0)"] ?? -1) >= start }
            }) {
                // A beat for the live mark that may follow a cached one.
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                return LaunchTTIUITests.marks(in: app)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return marks
    }

    static func round(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The cold half: each test is one launch, the first since the simulator booted.
final class ReadFirstColdUITests: ReadFirstUITests {
    override var phase: String { "cold" }

    @MainActor override func testColdLaunchWarm() throws { throw XCTSkip("warm runs in ReadFirstUITests") }
    @MainActor override func testWarmForegroundWarm() throws { throw XCTSkip("warm runs in ReadFirstUITests") }
    @MainActor override func testOpenChatWarm() throws { throw XCTSkip("warm runs in ReadFirstUITests") }
    @MainActor override func testOpenTerminalWarm() throws { throw XCTSkip("warm runs in ReadFirstUITests") }
    @MainActor override func testSwitchSessionWarm() throws { throw XCTSkip("warm runs in ReadFirstUITests") }

    @MainActor func testColdLaunchCold() throws { try cold(.coldLaunch) }
    @MainActor func testOpenChatCold() throws { try cold(.openChat) }
    @MainActor func testOpenTerminalCold() throws { try cold(.openTerminal) }
    @MainActor func testSwitchSessionCold() throws { try cold(.switchSession) }

    @MainActor
    private func cold(_ tap: Tap) throws {
        let app = LaunchTTIUITests.makeApp()
        app.launch()
        try run(tap, app: app)
    }
}
