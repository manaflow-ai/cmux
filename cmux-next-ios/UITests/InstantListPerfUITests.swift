import XCTest

/// The UI half of the iOS "instant list" bench: the Home list of sessions should
/// load near-instantly and behave the same with 5,000 rows ("god") as with 20
/// ("small"). This measures what the kit can't: launch to the first visible
/// Home row, and scrolling the real list. The kit half is the Swift Testing target
/// `CmuxMobileInstantPerfTests`; targets and method are in
/// `cmux-next-ios/design/instant-perf.md`.
///
/// Sizes: SMALL = 20 Home rows, GOD = 5,000, seeded by the list rig in mock mode
/// (`CMUX_MOBILE_MOCK_AUTH=1`, `CMUX_MOBILE_LIST_SCREEN=home`, `CMUX_MOBILE_LIST_COUNT=N`,
/// `CMUX_MOBILE_LIST_PASSES=0`, so the rig seeds `MacHomeFeed.seedStressRows` and holds).
/// Rows 0-3 are pinned tiles, so the first list row is `home.row.stress-4`.
///
/// Targets:
/// - first Home row visible: cold launch 300 ms, warm launch 100 ms (from the phone's kept rows)
/// - scroll: no hitches (scrollingAndDeceleration hitch ratio near 0)
/// - god within 1.2x of small, on every measure
///
/// Numbers: Xcode's perf metrics (`XCTApplicationLaunchMetric`, `XCTClockMetric`,
/// `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTCPUMetric`) land in the
/// result bundle. The custom time-to-first-row measure also prints one line per
/// iteration, `INSTANTPERF {"metric":"...","size":"small|god","ms":N}`, for grepping
/// the console log. It includes `XCUIApplication.launch()`'s own wait for the app
/// to go idle, so it is an upper bound on what a person sees.
///
/// Run on owned simulators:
///     scripts/ci/cmux-next-ios-sim.sh test ui=InstantListPerfUITests
/// or plain xcodebuild:
///     xcodebuild test -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp \
///       -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:CmuxMobileAppUITests/InstantListPerfUITests
final class InstantListPerfUITests: XCTestCase {
    private enum Size: String {
        case small, god
        var rows: Int { self == .small ? 20 : 5_000 }
    }

    /// The first non-pinned Home row (rows 0-3 are pinned tiles).
    private static let firstRowID = "home.row.stress-4"
    private static let iterations = 5

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Launch to first Home row

    @MainActor func testColdLaunchSmall() throws { try coldLaunch(.small) }
    @MainActor func testColdLaunchGod() throws { try coldLaunch(.god) }
    @MainActor func testWarmLaunchSmall() throws { try warmLaunch(.small) }
    @MainActor func testWarmLaunchGod() throws { try warmLaunch(.god) }
    @MainActor func testFirstRowColdSmall() throws { try firstRow(.small, cold: true) }
    @MainActor func testFirstRowColdGod() throws { try firstRow(.god, cold: true) }
    @MainActor func testFirstRowWarmSmall() throws { try firstRow(.small, cold: false) }
    @MainActor func testFirstRowWarmGod() throws { try firstRow(.god, cold: false) }

    /// Xcode's launch metric to the first frame.
    @MainActor
    private func coldLaunch(_ size: Size) throws {
        let app = makeApp(size)
        try prepare(app)
        app.terminate()
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }

    /// Xcode's launch metric until the app is responsive, after a launch that
    /// warms the caches (the launch metric's warm-launch case).
    @MainActor
    private func warmLaunch(_ size: Size) throws {
        let app = makeApp(size)
        try prepare(app)
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
    }

    /// Launch to the first Home row existing, timed by `XCTClockMetric` (result
    /// bundle) and `ContinuousClock` (the INSTANTPERF line). Cold terminates the app
    /// before each iteration (outside the measured span); warm relaunches it over
    /// the one already running (`launch()` terminates it first).
    @MainActor
    private func firstRow(_ size: Size, cold: Bool) throws {
        let app = makeApp(size)
        try prepare(app)
        let metric = cold ? "first_row_cold" : "first_row_warm"
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        options.invocationOptions = [.manuallyStart]
        var samples: [Double] = []
        measure(metrics: [XCTClockMetric()], options: options) {
            if cold { app.terminate() }
            let clock = ContinuousClock()
            let start = clock.now
            startMeasuring()
            app.launch()
            let found = app.buttons[Self.firstRowID].waitForExistence(timeout: 60)
            stopMeasuring()
            let ms = Self.milliseconds(clock.now - start)
            XCTAssertTrue(found, "first Home row (\(size.rawValue))\n\(app.debugDescription)")
            samples.append(ms)
            print(#"INSTANTPERF {"metric":"\#(metric)","size":"\#(size.rawValue)","ms":\#(Int(ms.rounded()))}"#)
        }
        let median = samples.sorted()[samples.count / 2]
        print(#"INSTANTPERF {"metric":"\#(metric)_median","size":"\#(size.rawValue)","ms":\#(Int(median.rounded()))}"#)
    }

    // MARK: Scroll

    @MainActor func testScrollSmall() throws { try scroll(.small) }
    @MainActor func testScrollGod() throws { try scroll(.god) }

    /// Flicks the Home list up and down; Xcode records hitches and the app's CPU.
    @MainActor
    private func scroll(_ size: Size) throws {
        let app = makeApp(size)
        try prepare(app)
        let list = app.collectionViews.firstMatch
        let target: XCUIElement = list.exists ? list : app
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)],
                options: options) {
            target.swipeUp(velocity: .fast)
            target.swipeUp(velocity: .fast)
            target.swipeDown(velocity: .fast)
            target.swipeDown(velocity: .fast)
        }
    }

    // MARK: Reconnect

    func testReconnectAfterNetworkChange() throws {
        throw XCTSkip("""
            not wired: needs a DEBUG link-drop hook. Mock auth has no Mac link, and no launch \
            argument drops one. Needed: a DEBUG argument (e.g. `-cmux-mobile-link-drop-after S`) that \
            sends LinkController `.linkDropped` on a live or loopback Mac link, and a Home signal \
            that the list reconnected (rows refreshed from the new link), timed drop to refreshed.
            """)
    }

    // MARK: Fold and unfold (iPhone Duo)

    func testFoldTransitionKeepsSelectionAndScroll() throws {
        throw XCTSkip("""
            not wired: the app has no two-column layout yet (cmuxterm-hq \
            plans/feat-ios-instant-list/DESIGN.md, section 8 and metric 11). The case, small vs god: \
            open a chat, scroll the list and the transcript, change the posture (folded to unfolded and \
            back), and assert the selected chat and both scroll anchors are unchanged (0 pt), nothing \
            reloaded (no loading note, no new attach), and the change lands within one frame. The \
            first-row and chat-open targets are then run in both postures.
            """)
    }

    // MARK: Launch setup

    @MainActor
    private func makeApp(_ size: Size) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "home"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(size.rows)
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        return app
    }

    /// One unmeasured launch: installs caches, gets past a team chooser if setup
    /// shows one, and checks the first row appears at all.
    @MainActor
    private func prepare(_ app: XCUIApplication) throws {
        app.launch()
        let row = app.buttons[Self.firstRowID]
        if !row.waitForExistence(timeout: 30) {
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.exists { app.buttons["Manaflow"].tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 30), "first Home row\n\(app.debugDescription)")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
