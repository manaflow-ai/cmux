import XCTest

/// Workspaces list edge cases on the list rig's 60 seeded workspaces (`CMUX_MOBILE_LIST_SCREEN=
/// workspaces`), measured from accessibility frames, not by eye:
/// - WS-15: the workspace being read is deleted on the Mac (the rig's `remove` signal: the Mac's
///   tree without it). It leaves the list, the rows above it stay put and the rows below move up by
///   exactly its pitch, so the next row takes its place; nothing else moves (SB, 0.5 pt).
/// - WS-19: turning the iPhone to landscape and back keeps the row being read where it was. The app
///   is portrait-only on a phone's screen (project.yml, `ScreenSharingOrientation.resting`), so the
///   window must not turn either.
final class WorkspacesEdgeUITests: XCTestCase {
    static let removed = "ws-s20"

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch() -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SIGNALS"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_REMOVE_ID"] = Self.removed
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Workspaces list\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["workspace.row.ws-s1"].waitForExistence(timeout: 20), "the seeded rows\n\(app.debugDescription)")
        return (app, list)
    }

    /// WS-15.
    @MainActor
    func testRowRemovedWhileReadClosesItsGapOnly() {
        let (app, list) = launch()
        defer { app.terminate() }
        let row = app.buttons["workspace.row.\(Self.removed)"]
        RowFrames.bring(row, toMiddleOf: list)
        XCTAssertTrue(row.exists && row.isHittable, "the row to remove is on screen\n\(app.debugDescription)")
        let before = RowFrames.settled(list, prefix: "workspace.row.")
        XCTAssertNotNil(before["workspace.row.\(Self.removed)"], "the row is measured: \(before.keys.sorted())")
        edgeShot(app, "ws15-1-reading")

        RigSignal.post("remove")
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the deleted workspace leaves the list\n\(app.debugDescription)")
        let after = RowFrames.settled(list, prefix: "workspace.row.")
        edgeShot(app, "ws15-2-removed")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        let report = RowFrames.expectGapClosed(before: before, after: after, removed: "workspace.row.\(Self.removed)")
        edgeNote(report, "ws15-frames")

        // The list still scrolls and the row stays gone.
        RowFrames.drag(list, by: -200)
        XCTAssertFalse(row.exists, "the deleted workspace does not come back")
        edgeShot(app, "ws15-3-scrolled")
    }

    /// WS-19.
    @MainActor
    func testRotationKeepsTheRowBeingRead() throws {
        let (app, list) = launch()
        defer { app.terminate() }
        let target = app.buttons["workspace.row.\(Self.removed)"]
        RowFrames.bring(target, toMiddleOf: list)
        let before = RowFrames.settled(list, prefix: "workspace.row.")
        let reader = try XCTUnwrap(RowFrames.reader(before, in: list), "a row being read")
        let window = app.windows.firstMatch.frame
        edgeShot(app, "ws19-1-portrait")
        var lines = ["reader \(reader) at \(before[reader]!)", "window \(window)"]

        for (step, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            let frames = RowFrames.settled(list, prefix: "workspace.row.")
            let turned = app.windows.firstMatch.frame
            edgeShot(app, "ws19-\(step + 2)-\(orientation == .portrait ? "portrait" : "landscape")")
            lines.append("step \(step) orientation \(orientation.rawValue): window \(turned), reader \(frames[reader].map { "\($0)" } ?? "off screen")")
            XCTAssertEqual(turned.width < turned.height, true, "a phone's screen stays portrait (window \(turned))")
            let now = try XCTUnwrap(frames[reader], "the row being read stays on screen at step \(step)")
            XCTAssertLessThanOrEqual(abs(now.minY - before[reader]!.minY), RowFrames.shiftBar,
                                     "the row being read moved \(now.minY - before[reader]!.minY) pt at step \(step)")
        }
        edgeNote(lines.joined(separator: "\n"), "ws19-frames")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
    }
}
