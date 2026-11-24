import XCTest

/// Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all these
/// placeholders doen and prevent them". The check `ios-placeholder-bounds`, on the simulator: each
/// of his flows is driven with `-cmux-placeholder-markers`, so every view under `.placeholderBound`
/// (CmuxMobileDesign/PlaceholderBound.swift) draws a marker `placeholder.<id>.<bound ms>`. The run
/// samples the screen and fails when a marker stays on screen past its bound. Every placeholder id
/// and its bound is in cmux-next-ios/design/placeholders.json; the headless half
/// (scripts/ci/ios_placeholder_bounds.py) keeps every placeholder in the sources under a bound.
///
/// His screenshots were a workspace of 51 tabs: the tab grid (black and globe thumbnails, prohibited
/// signs), a chat (an empty user bubble, a prohibited-sign subagent row), the composer under a
/// "Connecting" chip, and the workspaces list ("3 of 3 Macs online", rows greyed).
final class PlaceholderBoundUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// The workspaces list, then the tab grid of a 51-tab workspace (the rig's agent, terminal and
    /// browser tabs in turn), cold: no Mac push and no card pictures drawn this launch.
    @MainActor
    func testTabGridOf51TabsLeavesNoPlaceholderPastItsBound() {
        let app = Self.app()
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "51"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_NO_CARD_PICTURES"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
        watch(app, flow: "tab-grid-51", for: 12) { app.swipeUp() }
    }

    /// The workspaces list as it opens.
    @MainActor
    func testWorkspacesListLeavesNoPlaceholderPastItsBound() {
        let app = Self.app(demo: "workspaces")
        app.launch()
        defer { app.terminate() }
        watch(app, flow: "workspaces", for: 10)
    }

    /// An open chat with subagents and attachments, and one whose Mac answers 4 s late.
    @MainActor
    func testChatLeavesNoPlaceholderPastItsBound() {
        for demo in ["disclosure-chat", "slow-history-chat"] {
            let app = Self.app(demo: demo)
            app.launch()
            watch(app, flow: demo, for: 12)
            app.terminate()
        }
    }

    /// A reply sent while the link is down (the composer's connection state).
    @MainActor
    func testOfflineSendLeavesNoPlaceholderPastItsBound() {
        let app = Self.app(demo: "offline-send")
        app.launch()
        defer { app.terminate() }
        watch(app, flow: "offline-send", for: 12)
    }

    // MARK: The watch

    private static func app(demo: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-placeholder-markers"]
        if let demo { app.launchArguments += ["-cmux-mobile-demo", demo] }
        return app
    }

    /// Samples the screen every 0.25 s for `seconds`, calling `step` (a scroll) every 2 s, and fails
    /// for each marker on screen without a break for longer than its bound. A marker that leaves and
    /// comes back starts a new stay.
    @MainActor
    private func watch(_ app: XCUIApplication, flow: String, for seconds: Double, step: (() -> Void)? = nil) {
        let markers = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placeholder.'"))
        let start = Date()
        var since: [String: Date] = [:]
        var overstayed: [String: Double] = [:]
        var lastStep = start
        while Date().timeIntervalSince(start) < seconds {
            let now = Date()
            let shown = Set(markers.allElementsBoundByIndex.map(\.identifier))
            since = since.filter { shown.contains($0.key) }
            for id in shown {
                let first = since[id] ?? now
                since[id] = first
                let stay = now.timeIntervalSince(first)
                if let bound = Self.boundSeconds(id), stay > bound { overstayed[id] = max(overstayed[id] ?? 0, stay) }
            }
            if let step, now.timeIntervalSince(lastStep) >= 2 { step(); lastStep = now }
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.25)
        }
        for (id, stay) in overstayed.sorted(by: { $0.key < $1.key }) {
            print("PLACEHOLDER_OVERSTAY flow=\(flow) id=\(id) stay_s=\(String(format: "%.2f", stay))")
            XCTFail("\(flow): placeholder \(id) stayed \(String(format: "%.1f", stay)) s, past its bound")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(flow)-end"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// `placeholder.<id>.<ms>` -> seconds.
    private static func boundSeconds(_ identifier: String) -> Double? {
        guard let ms = identifier.split(separator: ".").last.flatMap({ Double($0) }) else { return nil }
        return ms / 1000
    }
}
