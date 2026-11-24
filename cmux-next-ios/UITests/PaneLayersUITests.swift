import XCTest

/// Leo, 2026-11-24: "i tried to swipe back as well and saw immediate overlapping text + search bar
/// which made things overlap, which is bad. we need to be treating the layers of panes better."
///
/// A swipe back from a workspace, held halfway: only one pane's header shows over each pane. The
/// Workspaces bar (its title, "N of M Macs online", its Search drawer) draws only over the list
/// sliding in, never over the workspace still on top. The `debug.pane-layers` probe
/// (`-CmuxMobilePaneLayerProbe`) reads, every frame of the transition, how far the drawn bar
/// reaches over the workspace pane (`overlap`, points).
final class PaneLayersUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore", "-CmuxMobilePaneLayerProbe"] + extra
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Every mock workspace (terminal, agent chat, browser): a held swipe back draws no bar over
    /// the workspace.
    @MainActor
    func testHeldSwipeBackShowsOneHeaderPerPane() {
        let app = launch()
        for workspace in ["ws-cmux", "ws-web", "ws-ios"] {
            let overlap = heldSwipeBack(app, workspace)
            XCTAssertNotNil(overlap, "\(workspace): the probe saw no transition frame")
            XCTAssertLessThanOrEqual(overlap ?? .max, 1, "\(workspace): the Workspaces bar drew \(overlap ?? -1) pt over the workspace mid swipe back")
        }
    }

    /// The control: with the mask off (UIKit's bar as it draws by itself) the same probe sees
    /// the bar over the workspace, the overlap of Leo's screenshot. Proves the probe sees it.
    @MainActor
    func testProbeSeesTheOverlapWithoutTheMask() {
        let app = launch(["-CmuxMobilePaneLayerNoMask"])
        let overlap = heldSwipeBack(app, "ws-cmux", label: "nomask")
        XCTAssertGreaterThan(overlap ?? 0, 20, "without the mask the bar is expected over the workspace (probe \(overlap ?? -1))")
    }

    /// Opens the workspace, swipes back from the edge to mid screen and holds, then lets go and
    /// finishes the pop. Returns the probe's largest overlap so far (nil: no sample).
    @MainActor
    func heldSwipeBack(_ app: XCUIApplication, _ workspace: String, label: String = "mask") -> Int? {
        let row = app.buttons["workspace.row.\(workspace)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(workspace): row")
        row.tap()
        let page = app.descendants(matching: .any)["workspace.\(workspace)"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "\(workspace): workspace not shown")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attach(app, "\(label)-\(workspace)-open")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                    withVelocity: 300, thenHoldForDuration: 1.5)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attach(app, "\(label)-\(workspace)-after-held-swipe")
        // Back to the list (the held swipe may have been cancelled).
        if !row.isHittable {
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(workspace): back on Workspaces")
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let probe = app.staticTexts["debug.pane-layers"]
        guard probe.waitForExistence(timeout: 5) else { return nil }
        let line = probe.value as? String ?? ""
        print("CMUX_PANE_LAYERS \(label) \(workspace): \(line)")
        XCTContext.runActivity(named: "\(label) \(workspace): \(line)") { _ in }
        let values = Dictionary(line.split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { _, last in last })
        guard let samples = Int(values["samples"] ?? ""), samples > 0 else { return nil }
        return Int(values["overlap"] ?? "")
    }
}
