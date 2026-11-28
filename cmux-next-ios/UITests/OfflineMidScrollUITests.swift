import XCTest

/// WS-16, beside OfflineWorkspaceAlertUITests: the rows' Mac goes offline while the list is
/// scrolled (the rig's `mac-offline` signal: presence says `mac-studio` is offline). The list keeps
/// its rows (the offline Mac's rows, last known), the subtitle changes, the list still scrolls, and
/// when the Mac comes back (`mac-online`) the list is not reset to its top: the row being read stays
/// on screen. Every position is read from accessibility frames; the shifts are attached.
final class OfflineMidScrollUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func subtitle(_ app: XCUIApplication) -> String {
        let bar = app.navigationBars["Workspaces"]
        let texts = bar.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0 != "Workspaces" && !$0.isEmpty }
        return texts.joined(separator: " | ")
    }

    @MainActor
    func testMacOfflineMidScrollKeepsRowsAndPlace() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SIGNALS"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Workspaces list\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["workspace.row.ws-s1"].waitForExistence(timeout: 20), "the seeded rows\n\(app.debugDescription)")
        let top = RowFrames.settled(list, prefix: "workspace.row.")
        let firstRow = try XCTUnwrap(top.min { $0.value.minY < $1.value.minY }?.key, "a first row")

        // Mid-list, reading.
        let target = app.buttons["workspace.row.ws-s23"]
        RowFrames.bring(target, toMiddleOf: list)
        let reading = RowFrames.settled(list, prefix: "workspace.row.")
        let reader = try XCTUnwrap(RowFrames.reader(reading, in: list), "a row being read")
        let online = subtitle(app)
        var lines = ["first row \(firstRow)", "reader \(reader) at \(reading[reader]!)", "subtitle online: '\(online)'"]
        edgeShot(app, "ws16-1-online-reading")

        // The Mac goes offline.
        RigSignal.post("mac-offline")
        let switched = NSPredicate { _, _ in self.subtitle(app) != online }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: switched, object: nil)], timeout: 10), .completed,
                       "the subtitle changes when the Mac goes offline (still '\(subtitle(app))')")
        let offline = RowFrames.settled(list, prefix: "workspace.row.")
        lines.append("subtitle offline: '\(subtitle(app))'")
        lines.append("offline: \(offline.count) rows on screen, reader \(offline[reader].map { "\($0)" } ?? "off screen")")
        edgeShot(app, "ws16-2-offline")
        XCTAssertGreaterThan(offline.count, 3, "the list keeps its rows\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons[reader].exists, "the row being read is still listed")
        if reading[firstRow] == nil { XCTAssertNil(offline[firstRow], "going offline does not reset the list to its top") }

        // Scrolling goes on while the Mac is offline.
        RowFrames.drag(list, by: -240)
        let scrolled = RowFrames.settled(list, prefix: "workspace.row.")
        let moved = scrolled.contains { key, frame in offline[key].map { abs($0.minY - frame.minY) > 50 } ?? true }
        XCTAssertTrue(moved, "the list scrolls while its Mac is offline")
        edgeShot(app, "ws16-3-offline-scrolled")

        // The Mac comes back: the list keeps its place.
        let back = try XCTUnwrap(RowFrames.reader(scrolled, in: list), "a row being read offline")
        let offlineSubtitle = subtitle(app)
        RigSignal.post("mac-online")
        let restored = NSPredicate { _, _ in self.subtitle(app) != offlineSubtitle }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 10), .completed,
                       "the subtitle changes back when the Mac comes back (still '\(subtitle(app))')")
        let reconnected = RowFrames.settled(list, prefix: "workspace.row.")
        lines.append("reader offline \(back) at \(scrolled[back]!)")
        lines.append("subtitle back online: '\(subtitle(app))'")
        lines.append("reconnected: reader \(reconnected[back].map { "\($0)" } ?? "off screen"), first row visible: \(reconnected[firstRow] != nil)")
        edgeShot(app, "ws16-4-reconnected")
        edgeNote(lines.joined(separator: "\n"), "ws16-frames")
        XCTAssertNotNil(reconnected[back], "reconnecting keeps the row being read on screen")
        XCTAssertNil(reconnected[firstRow], "reconnecting does not reset the list to its top")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
    }
}
