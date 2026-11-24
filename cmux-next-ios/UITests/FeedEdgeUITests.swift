import XCTest

/// Feed edge cases on the stress rig's 60 events (`CMUX_MOBILE_FEED_STRESS=60`), measured from
/// accessibility frames:
/// - FEED-13: the event being read is marked done elsewhere (the rig's `remove` signal:
///   `FeedStore.remove`, as `TerminalFeed` drops one the Mac acknowledged) while its swipe actions
///   are open. It leaves the list, the rows above stay put, the rows below move up by its pitch
///   (SB, 0.5 pt), and no swipe action is left open for the removed row.
/// - FEED-14 (landscape): turning the iPhone keeps the event being read where it was; a phone's
///   screen stays portrait.
final class FeedEdgeUITests: XCTestCase {
    /// An answer mid-list (its swipe actions: Done and Read), below the open asks the Feed pins
    /// first (`pinningNeedsYou`: about 22 of the 60 stress events, many screens). A person reaches
    /// it by scrolling past them; the test's slow drags never did in 30 tries, so the rig's
    /// `reveal` scrolls the list by its own offset to it, and a short drag then settles it.
    static let removed = "stress-20"
    /// The events' own cells. Not "feed.row.": a row's Show More button is "feed.row.showMore",
    /// and it was measured as the next row (edgeui-5: a 367 pt "pitch" that was the button inside
    /// the removed row, against the row's real 455 pt).
    static let rowPrefix = "feed.row.stress-"

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
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "feed"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SIGNALS"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_REMOVE_ID"] = Self.removed
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Feed's table\n\(app.debugDescription)")
        XCTAssertTrue(list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'")).firstMatch.waitForExistence(timeout: 20),
                      "the stress events\n\(app.debugDescription)")
        return (app, list)
    }

    /// FEED-13.
    @MainActor
    func testEventRemovedWhileReadLeavesTheOthersInPlace() {
        let (app, list) = launch()
        defer { app.terminate() }
        let row = list.cells["feed.row.\(Self.removed)"]
        RigSignal.post("reveal")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the rig scrolled to the event\n\(app.debugDescription)")
        RowFrames.bring(row, toMiddleOf: list)
        XCTAssertTrue(row.exists && row.isHittable, "the event to remove is on screen\n\(app.debugDescription)")
        let before = RowFrames.settled(list, prefix: Self.rowPrefix)
        XCTAssertNotNil(before["feed.row.\(Self.removed)"], "the event is measured: \(before.keys.sorted())")
        // Mid-list, as a reader is: rows on screen above and below it, and a screen of rows above.
        let gone = before["feed.row.\(Self.removed)"]!
        XCTAssertTrue(before.values.contains { $0.maxY <= gone.minY + RowFrames.shiftBar }, "a row above it on screen: \(before)")
        XCTAssertTrue(before.values.contains { $0.minY >= gone.maxY - RowFrames.shiftBar }, "a row below it on screen: \(before)")
        XCTAssertNil(before["feed.row.stress-2"], "the list is scrolled down: the first ask is a screen or more above")

        // Its swipe actions open (UIKit's trailing actions: Done and Read on an answer).
        let reads = list.buttons.matching(NSPredicate(format: "label IN {'Read', 'Unread', 'Done'}"))
        let closedCount = reads.count
        row.swipeLeft()
        XCTAssertTrue(list.buttons["Done"].waitForExistence(timeout: 5) || reads.count > closedCount,
                      "the swipe actions open\n\(app.debugDescription)")
        let openCount = reads.count
        edgeShot(app, "feed13-1-swipe-open")
        // What the reader sees just before the Mac withdraws it (with the swipe actions open).
        let opened = RowFrames.settled(list, prefix: Self.rowPrefix)
        edgeNote("before swipe: \(before.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.minY)" })\n"
                 + "swipe open: \(opened.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.minY)" })", "feed13-swipe-frames")

        RigSignal.post("remove")
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the event leaves the Feed\n\(app.debugDescription)")
        let after = RowFrames.settled(list, prefix: Self.rowPrefix)
        edgeShot(app, "feed13-2-removed")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        let noStale = NSPredicate { _, _ in reads.count == closedCount }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: noStale, object: nil)], timeout: 5), .completed,
                       "no swipe action stays open for the removed event (Done/Read/Unread swipe buttons: \(closedCount) closed, \(openCount) open, \(reads.count) now)")
        let report = RowFrames.expectGapClosed(before: opened, after: after, removed: "feed.row.\(Self.removed)")
        edgeNote(report + "\nswipe buttons closed=\(closedCount) open=\(openCount) after=\(reads.count)", "feed13-frames")

        // The row now in its place swipes as itself.
        if let next = after.filter({ $0.value.minY >= (opened["feed.row.\(Self.removed)"] ?? gone).minY - RowFrames.shiftBar })
            .min(by: { $0.value.minY < $1.value.minY })?.key {
            let cell = list.cells[next]
            cell.swipeLeft()
            edgeShot(app, "feed13-3-next-swiped")
            XCTAssertTrue(cell.exists, "\(next) is still listed after its own swipe")
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
    }

    /// FEED-14, landscape.
    @MainActor
    func testRotationKeepsTheEventBeingRead() throws {
        let (app, list) = launch()
        defer { app.terminate() }
        RowFrames.bring(list.cells["feed.row.\(Self.removed)"], toMiddleOf: list)
        let before = RowFrames.settled(list, prefix: Self.rowPrefix)
        let reader = try XCTUnwrap(RowFrames.reader(before, in: list), "an event being read")
        edgeShot(app, "feed14-1-portrait")
        var lines = ["reader \(reader) at \(before[reader]!)", "window \(app.windows.firstMatch.frame)"]
        for (step, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            let frames = RowFrames.settled(list, prefix: Self.rowPrefix)
            let turned = app.windows.firstMatch.frame
            edgeShot(app, "feed14-\(step + 2)-\(orientation == .portrait ? "portrait" : "landscape")")
            lines.append("step \(step) orientation \(orientation.rawValue): window \(turned), reader \(frames[reader].map { "\($0)" } ?? "off screen")")
            XCTAssertTrue(turned.width < turned.height, "a phone's screen stays portrait (window \(turned))")
            let now = try XCTUnwrap(frames[reader], "the event being read stays on screen at step \(step)")
            XCTAssertLessThanOrEqual(abs(now.minY - before[reader]!.minY), RowFrames.shiftBar,
                                     "the event being read moved \(now.minY - before[reader]!.minY) pt at step \(step)")
        }
        edgeNote(lines.joined(separator: "\n"), "feed14-frames")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
    }
}
