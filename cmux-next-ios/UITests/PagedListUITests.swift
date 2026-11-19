import XCTest

/// The shared infinite-scroll list (`PagedList`, verify/paged-list.md) in its lab
/// (`-cmux-mobile-paged-lab DIRECTION:SCENARIO`): a page that lands while the reader holds still
/// moves no row on screen (measured from outside, by the row's frame, and inside, by the lab's
/// probe); an `.up` list opens at its newest row and stays on it through the keyboard and a sent
/// row; every state shows (first-page failure and Try Again, empty, the edge's failure and Try
/// Again, the end); flings meet rows, and their frames are counted (PAGEDLIST lines).
final class PagedListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: A page lands, the reader's row stays

    @MainActor func testDownPageLandsWithoutMovingTheReader() {
        let app = launch("down:slow")
        assertPagesLandInPlace(app, direction: .down, name: "down")
    }

    @MainActor func testUpPageLandsWithoutMovingTheReader() {
        let app = launch("up:slow")
        assertOpensAtNewest(app)
        assertPagesLandInPlace(app, direction: .up, name: "up")
    }

    @MainActor func testUpPageLandsWithoutMovingTheReaderAtAccessibilityTextSize() {
        let app = launch("up:slow", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        assertOpensAtNewest(app)
        assertPagesLandInPlace(app, direction: .up, name: "up-ax")
    }

    @MainActor func testDownPageLandsWithoutMovingTheReaderAtAccessibilityTextSize() {
        let app = launch("down:slow", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        assertPagesLandInPlace(app, direction: .down, name: "down-ax")
    }

    // MARK: Newest end

    @MainActor func testUpStaysOnNewestThroughKeyboardAndSend() {
        let app = launch("up:normal")
        assertOpensAtNewest(app)
        let composer = app.textFields["lab.composer"]
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        settle(app.descendants(matching: .any)["lab.row.0"])
        attach(app, "up-keyboard")
        let newest = app.descendants(matching: .any)["lab.row.0"]
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY + 1, "the newest row went under the keyboard's composer")
        XCTAssertGreaterThan(newest.frame.maxY, composer.frame.minY - 120, "the list left its newest row when the keyboard came up")
        composer.typeText("Hello from the test")
        app.buttons["lab.send"].tap()
        let sent = app.descendants(matching: .any)["lab.row.-1001"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the sent row did not show")
        settle(sent)
        attach(app, "up-sent")
        XCTAssertLessThanOrEqual(sent.frame.maxY, composer.frame.minY + 1, "the sent row is under the composer")
        XCTAssertGreaterThan(sent.frame.maxY, composer.frame.minY - 120, "the list did not follow the sent row")
        // It slid up from under the composer over many frames (Messages), not a one-frame jump.
        let reading = hud(app)
        record("up-send-slide", reading.json)
        XCTAssertGreaterThanOrEqual(reading.slides, 1, "the list did not slide to the sent row")
        XCTAssertGreaterThan(reading.slideFrames, 5, "the sent row jumped into place (\(reading.slideFrames) frames)")
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5, "a row moved \(reading.frameShift) pt in a frame the slide does not explain")
    }

    /// A row that arrives while a `.down` reader is at the top slides in from above: the rows stay
    /// put for a frame, then the list slides to the new top over many frames.
    @MainActor func testDownNewRowSlidesInAtTheTop() {
        let lab = PagedLabDriver.launch("down:normal", test: self)
        XCTAssertTrue(lab.row(0).waitForExistence(timeout: 10))
        lab.settle(lab.row(0))
        let top = lab.row(0).frame.minY
        lab.app.buttons["lab.op.insert"].tap()
        let arrived = lab.row(-2)
        XCTAssertTrue(arrived.waitForExistence(timeout: 5), "the new row did not show")
        lab.waitFor("the slide", timeout: 5) { lab.reading.slides >= 1 }
        lab.settle(arrived)
        lab.attach("down-new-row-at-top")
        let reading = lab.reading
        lab.record("down-new-row-slide", reading.json)
        XCTAssertEqual(arrived.frame.minY, top, accuracy: 1, "the list did not end at its new top")
        XCTAssertGreaterThan(reading.slideFrames, 5, "the new row jumped into place (\(reading.slideFrames) frames)")
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5, "a row moved \(reading.frameShift) pt in a frame the slide does not explain")
    }

    /// A row that arrives under a resting finger (touching the list, not dragging) waits: the rows
    /// under the finger stay, and the new row slides in when it lifts. The spring waits for the
    /// finger instead of stalling or jumping, and the indicator never counts a row the list slid to.
    @MainActor func testUpRowArrivingUnderARestingFingerSlidesInWhenItLifts() {
        let lab = PagedLabDriver.launch("up:normal", test: self)
        XCTAssertTrue(lab.row(0).waitForExistence(timeout: 10))
        lab.settle(lab.row(0))
        let slides = lab.reading.slides
        // The row lands 2.5 s after the tap; the finger rests from before that until after it.
        lab.app.buttons["lab.op.later"].tap()
        lab.list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 5)
        let arrived = lab.row(-2)
        XCTAssertTrue(arrived.waitForExistence(timeout: 5), "the new row did not show")
        lab.waitFor("the slide", timeout: 5) { lab.reading.slides > slides }
        lab.settle(arrived)
        lab.attach("up-resting-finger-slid-in")
        let reading = lab.reading
        lab.record("up-resting-finger", reading.json)
        XCTAssertGreaterThanOrEqual(reading.held, 1, "the row did not land under the resting finger (the press came late)")
        XCTAssertLessThanOrEqual(arrived.frame.maxY, lab.floor + 1, "the new row is under the composer")
        XCTAssertGreaterThan(arrived.frame.maxY, lab.floor - 60, "the list did not slide on to the new row")
        XCTAssertGreaterThan(reading.slideFrames, 5, "the new row jumped into place (\(reading.slideFrames) frames)")
        XCTAssertFalse(lab.app.buttons["pagedList.newest"].exists, "the indicator shows for a row the list slid to")
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5, "a row moved \(reading.frameShift) pt in a frame the slide does not explain")
    }

    /// The composer rides the keyboard mid-list and the rows ride with it (Telegram, Messages): the
    /// gap between the row being read and the composer stays the same, keyboard up and down.
    @MainActor func testUpComposerRidesTheKeyboardMidList() {
        let lab = PagedLabDriver.launch("up:normal", test: self)
        XCTAssertTrue(lab.row(0).waitForExistence(timeout: 10))
        for _ in 0..<3 { lab.drag(by: 360) }
        lab.settle(lab.list.cells.firstMatch)
        let composer = lab.app.textFields["lab.composer"]
        let row = lab.visibleRow(nearFloor: true)
        let gap = composer.frame.minY - row.frame.maxY
        composer.tap()
        XCTAssertTrue(lab.app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
        lab.settle(composer)
        lab.settle(row)
        lab.attach("up-ride-keyboard-up")
        XCTAssertTrue(row.exists, "the row being read left the list")
        XCTAssertEqual(composer.frame.minY - row.frame.maxY, gap, accuracy: 1, "the rows did not ride the composer up")
        composer.typeText("\n")
        lab.settle(composer)
        lab.settle(row)
        lab.attach("up-ride-keyboard-down")
        XCTAssertEqual(composer.frame.minY - row.frame.maxY, gap, accuracy: 1, "the rows did not ride the composer down")
        let reading = lab.reading
        lab.record("up-ride-keyboard", reading.json)
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5, "a row moved \(reading.frameShift) pt in a frame the ride does not explain")
    }

    /// The ready-made newest-rows pill: away from the newest end, three arrivals show "3 new"; a tap
    /// slides back to them and the pill goes.
    @MainActor func testUpNewestPillCountsArrivalsAndJumps() {
        let lab = PagedLabDriver.launch("up:normal", test: self)
        XCTAssertTrue(lab.row(0).waitForExistence(timeout: 10))
        for _ in 0..<4 { lab.drag(by: 420) }
        lab.settle(lab.list.cells.firstMatch)
        for _ in 0..<3 { lab.app.buttons["lab.op.insert"].tap() }
        let pill = lab.app.buttons["pagedList.newest"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no newest-rows pill")
        lab.waitFor("3 new", timeout: 5) { pill.label == "3 new" }
        lab.attach("up-pill-3-new")
        pill.tap()
        let newest = lab.row(-4)
        lab.waitFor("the newest row", timeout: 5) { newest.exists && newest.isHittable }
        lab.settle(newest)
        lab.attach("up-pill-jumped")
        XCTAssertLessThanOrEqual(newest.frame.maxY, lab.floor + 1, "the newest row is under the composer")
        XCTAssertGreaterThan(newest.frame.maxY, lab.floor - 60, "the pill did not take the list to its newest row")
        lab.waitFor("the pill to go", timeout: 3) { !pill.exists }
        lab.record("up-pill", lab.reading.json)
    }

    /// 100,000 rows with a window of 300 in memory, under a live load: flinging deep keeps memory
    /// bounded (the rest on disk), flinging back keeps it bounded, and the newest-rows pill takes the
    /// list back to its newest rows, read back from disk, with no row moving under the reader.
    @MainActor func testWindowedHugeListKeepsMemoryBounded() {
        continueAfterFailure = true
        let lab = PagedLabDriver.launch("down:normal", extra: ["-cmux-mobile-paged-lab-stress", "huge", "-cmux-mobile-paged-lab-window", "300"], test: self)
        // Any row: the load can move row 0 before the first look.
        XCTAssertTrue(lab.list.cells.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<40 { lab.scroll(towardOlder: true, direction: "down", speed: .fast) }
        lab.settle(lab.list.cells.firstMatch)
        lab.waitFor("rows spilled to disk", timeout: 5) { lab.reading.onDisk > 0 }
        let deep = lab.reading
        lab.attach("huge-deep")
        lab.record("huge-deep", deep.json)
        XCTAssertGreaterThan(deep.total, 1000, "the flings did not read deep (\(deep.total) rows)")
        XCTAssertLessThanOrEqual(deep.inMemory, 450, "\(deep.inMemory) row values in memory with a window of 300")
        XCTAssertGreaterThan(deep.onDisk, 0, "nothing went to disk")
        // Back toward the newest rows: the window reads them back from disk ahead of the reader.
        for _ in 0..<8 { lab.scroll(towardOlder: false, direction: "down", speed: .fast) }
        lab.settle(lab.list.cells.firstMatch)
        let partway = lab.reading
        lab.attach("huge-partway-back")
        XCTAssertLessThanOrEqual(partway.inMemory, 450, "\(partway.inMemory) row values in memory on the way back")
        // Ten rows a second arrive at the head, so scrolling never catches up with it: the newest-rows
        // pill jumps there (the window goes to the head and reads it back). Not row 0: the load
        // removes and moves rows at the head too.
        let pill = lab.app.buttons["pagedList.newest"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no newest-rows pill deep in the list")
        pill.tap()
        lab.waitFor("the newest rows back from disk", timeout: 10) { lab.reading.newer == "end" }
        lab.settle(lab.list.cells.firstMatch)
        lab.attach("huge-back-at-top")
        let back = lab.reading
        lab.record("huge-back", back.json)
        XCTAssertLessThanOrEqual(back.inMemory, 450, "\(back.inMemory) row values in memory on the way back")
        XCTAssertLessThanOrEqual(back.frameShift, 0.5, "a row moved \(back.frameShift) pt in a frame the scroll does not explain")
    }

    /// Rows a windowed list reads back from disk on the way back to its newest end are not new
    /// rows: with no live source, the pill never counts any (`.up`, where the newer edge is at the
    /// bottom and the reader parks on it after a fling).
    @MainActor func testWindowedRowsBackFromDiskAreNotNew() {
        continueAfterFailure = true
        let lab = PagedLabDriver.launch("up:fast", extra: ["-cmux-mobile-paged-lab-window", "150"], test: self)
        XCTAssertTrue(lab.row(0).waitForExistence(timeout: 15))
        for _ in 0..<24 { lab.scroll(towardOlder: true, direction: "up", speed: .fast) }
        lab.settle(lab.list.cells.firstMatch)
        lab.waitFor("rows spilled to disk", timeout: 5) { lab.reading.onDisk > 0 }
        let pill = lab.app.buttons["pagedList.newest"]
        var counted: [String] = []
        for _ in 0..<12 where lab.reading.newer != "end" {
            lab.scroll(towardOlder: false, direction: "up", speed: .fast)
            if pill.exists, pill.label.hasSuffix(" new") { counted.append(pill.label) }
        }
        lab.settle(lab.list.cells.firstMatch)
        if pill.exists, pill.label.hasSuffix(" new") { counted.append(pill.label) }
        lab.attach("up-window-back")
        lab.record("up-window-back", lab.reading.json)
        XCTAssertTrue(counted.isEmpty, "rows read back from disk counted as new: \(counted)")
    }

    // MARK: States

    @MainActor func testFirstPageFailureThenTryAgain() {
        let app = launch("down:firstfail")
        let failed = app.descendants(matching: .any)["lab.list.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "no first-page failure state")
        attach(app, "down-firstfail")
        failed.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 10), "Try Again did not load rows")
        attach(app, "down-firstfail-recovered")
    }

    @MainActor func testEmpty() {
        for lab in ["down:empty", "up:empty"] {
            let app = launch(lab)
            XCTAssertTrue(app.descendants(matching: .any)["lab.list.empty"].waitForExistence(timeout: 10), "no empty state (\(lab))")
            attach(app, lab.replacingOccurrences(of: ":", with: "-"))
            app.terminate()
        }
    }

    @MainActor func testLoadingFirstPage() {
        let app = launch("down:slow")
        XCTAssertTrue(app.descendants(matching: .any)["lab.list.loading"].waitForExistence(timeout: 5), "no first-page loading state")
        attach(app, "down-loading")
    }

    @MainActor func testEdgeFailureThenTryAgain() {
        let app = launch("down:morefail")
        XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 10))
        let failedEdge = app.descendants(matching: .any)["lab.list.edge.failed"]
        for _ in 0..<12 where !failedEdge.exists { app.collectionViews["lab.list"].swipeUp(velocity: .fast) }
        XCTAssertTrue(failedEdge.waitForExistence(timeout: 10), "the edge did not show the failure")
        attach(app, "down-edge-failed")
        app.buttons["lab.list.retry"].tap()
        waitFor("the next page after Try Again", timeout: 10) { self.hud(app).rows >= 60 }
        attach(app, "down-edge-recovered")
    }

    @MainActor func testEndOfList() {
        for (lab, label) in [("down:end", "You're all caught up"), ("up:end", "Beginning of the conversation")] {
            let app = launch(lab)
            XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 10))
            let end = app.descendants(matching: .any)["lab.list.edge.end"]
            let list = app.collectionViews["lab.list"]
            for _ in 0..<10 where !(end.exists && end.isHittable) {
                if lab.hasPrefix("down") { list.swipeUp(velocity: .fast) } else { list.swipeDown(velocity: .fast) }
            }
            XCTAssertTrue(end.waitForExistence(timeout: 10), "no end (\(lab))")
            XCTAssertTrue(app.staticTexts[label].exists, "no end label (\(lab))")
            XCTAssertEqual(hud(app).rows, 60, "the end did not stop at two pages (\(lab))")
            attach(app, lab.replacingOccurrences(of: ":", with: "-"))
            app.terminate()
        }
    }

    // MARK: Agent Chats (migrated screen)

    @MainActor func testAgentChatsLoadsOlderChatsAsYouScroll() {
        let app = launch("agentchats:pages")
        let list = app.collectionViews["agentChats.list"]
        XCTAssertTrue(app.descendants(matching: .any)["agentChats.row.chat-0"].waitForExistence(timeout: 10), "no chats")
        attach(app, "agentchats-first-page")
        XCTAssertFalse(app.buttons["agentChats.more"].exists, "Show Older Chats is still there")
        let last = app.descendants(matching: .any)["agentChats.row.chat-59"]
        for _ in 0..<15 where !(last.exists && last.isHittable) { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(last.waitForExistence(timeout: 10), "older chats did not load as the list scrolled")
        XCTAssertTrue(app.descendants(matching: .any)["agentChats.list.edge.end"].exists || !app.descendants(matching: .any)["agentChats.list.edge.more"].exists,
                      "the list did not end after the last page")
        attach(app, "agentchats-end")
    }

    @MainActor func testAgentChatsEdgeFailureThenTryAgain() {
        let app = launch("agentchats:edgefail")
        let list = app.collectionViews["agentChats.list"]
        XCTAssertTrue(app.descendants(matching: .any)["agentChats.row.chat-0"].waitForExistence(timeout: 10), "no chats")
        let failed = app.descendants(matching: .any)["agentChats.list.edge.failed"]
        for _ in 0..<12 where !failed.exists { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "the edge did not show the failure")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a failed page still shows an alert")
        attach(app, "agentchats-edge-failed")
        app.buttons["agentChats.list.retry"].tap()
        // The page lands below the edge, out of view: scroll to it.
        let landed = app.descendants(matching: .any)["agentChats.row.chat-25"]
        for _ in 0..<6 where !landed.waitForExistence(timeout: 2) { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(landed.exists, "Try Again did not load the page")
        attach(app, "agentchats-edge-recovered")
    }

    @MainActor func testAgentChatsLoadingEdgeAndEmpty() {
        let slow = launch("agentchats:slow")
        let list = slow.collectionViews["agentChats.list"]
        XCTAssertTrue(slow.descendants(matching: .any)["agentChats.row.chat-0"].waitForExistence(timeout: 10))
        let loading = slow.descendants(matching: .any)["agentChats.list.edge.loading"]
        for _ in 0..<4 where !loading.exists { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(loading.waitForExistence(timeout: 5), "no loading edge")
        attach(slow, "agentchats-edge-loading")
        slow.terminate()
        let empty = launch("agentchats:empty")
        XCTAssertTrue(empty.descendants(matching: .any)["agentChats.list.empty"].waitForExistence(timeout: 10), "no empty state")
        attach(empty, "agentchats-empty")
    }

    /// A page that repeats a chat id shows it once instead of crashing the diffable data source.
    @MainActor func testAgentChatsPageWithARepeatedChatShowsItOnce() {
        let app = launch("agentchats:dupes")
        let list = app.collectionViews["agentChats.list"]
        XCTAssertTrue(app.descendants(matching: .any)["agentChats.row.chat-0"].waitForExistence(timeout: 10), "no chats")
        let next = app.descendants(matching: .any)["agentChats.row.chat-25"]
        for _ in 0..<10 where !next.exists { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the next page did not load")
        XCTAssertEqual(app.state, .runningForeground, "the app crashed on a repeated id")
        attach(app, "agentchats-repeated-id")
    }

    /// An empty list still refreshes: pulling down on its empty state reads again.
    @MainActor func testAgentChatsEmptyListPullsToRefresh() {
        let app = launch("agentchats:emptythenone")
        let empty = app.descendants(matching: .any)["agentChats.list.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "no empty state")
        attach(app, "agentchats-empty-before-pull")
        let start = empty.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 360)))
        XCTAssertTrue(app.descendants(matching: .any)["agentChats.row.chat-0"].waitForExistence(timeout: 10),
                      "pulling the empty list did not refresh it")
        attach(app, "agentchats-empty-after-pull")
    }

    // MARK: Changes while the reader holds still mid-list

    /// Each change the list can get while someone reads the middle of it, none of which may move a
    /// row on screen: the reading row removed or moved to the newest end, a row above it growing, a
    /// newest row arriving, a top banner coming and going, the first page read again, and a rotation.
    @MainActor func testDownKeepsTheReaderThroughChanges() { assertKeepsTheReader("down:normal", direction: .down) }
    @MainActor func testUpKeepsTheReaderThroughChanges() { assertKeepsTheReader("up:normal", direction: .up) }

    @MainActor
    private func assertKeepsTheReader(_ lab: String, direction: Direction) {
        // Every change is measured and recorded, also after one fails.
        continueAfterFailure = true
        let app = launch(lab)
        XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 15))
        // Into the second page, then hold still with the edge idle.
        var drags = 0
        while hud(app).rows < 60 || drags < 6, drags < 40 {
            drag(app, by: direction == .down ? -420 : 420)
            drags += 1
        }
        waitFor("an idle edge", timeout: 10) { self.hud(app).edge == "more" }
        settle(app.collectionViews["lab.list"].cells.firstMatch)
        var results: [String] = []
        for (op, name) in [("grow", "a row above grows"), ("insert", "a newest row arrives"), ("banner", "a top banner shows"),
                           ("banner", "the top banner goes"), ("remove", "the reading row is removed"),
                           ("move", "the reading row moves to the newest end"), ("reload", "the first page is read again")] {
            let before = readableTops(app)
            XCTAssertFalse(before.isEmpty, "no rows on screen before \(name)")
            app.buttons["lab.op.\(op)"].tap()
            settle(app.collectionViews["lab.list"].cells.firstMatch)
            if op == "reload" {
                // The lab's source answers in 0.4 s: give the first page time to land.
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the first page lands")], timeout: 1.5)
                settle(app.collectionViews["lab.list"].cells.firstMatch)
            }
            let after = readableTops(app)
            let common = Set(before.keys).intersection(after.keys)
            let moved = common.map { abs(after[$0]! - before[$0]!) }.max() ?? -1
            results.append("{\"op\":\"\(name)\",\"rowsCompared\":\(common.count),\"shift\":\(moved)}")
            attach(app, "\(direction)-keeps-\(op)")
            XCTAssertGreaterThanOrEqual(common.count, 2, "\(name): the rows being read are gone (\(before.keys.sorted()) → \(after.keys.sorted()))")
            XCTAssertLessThanOrEqual(moved, 0.5, "\(name) moved the rows being read by \(moved) pt")
        }
        // A rotation and back: the same rows where they were.
        let before = readableTops(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(app.collectionViews["lab.list"].cells.firstMatch)
        attach(app, "\(direction)-keeps-landscape")
        XCUIDevice.shared.orientation = .portrait
        settle(app.collectionViews["lab.list"].cells.firstMatch)
        let after = readableTops(app)
        let common = Set(before.keys).intersection(after.keys)
        let moved = common.map { abs(after[$0]! - before[$0]!) }.max() ?? .infinity
        results.append("{\"op\":\"a rotation and back\",\"rowsCompared\":\(common.count),\"shift\":\(moved)}")
        record("keeps-\(direction)", "[" + results.joined(separator: ",") + "]")
        XCTAssertGreaterThanOrEqual(common.count, 2, "a rotation lost the rows being read")
        XCTAssertLessThanOrEqual(moved, 0.5, "a rotation and back moved the rows being read by \(moved) pt")
    }

    /// Tops of the rows below the navigation bar: the rows being read (rows under the bar are not).
    @MainActor
    private func readableTops(_ app: XCUIApplication) -> [String: CGFloat] {
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        return rowTops(app).filter { $0.value >= barBottom - 0.5 }
    }

    // MARK: Flings

    @MainActor func testDownFlingsMeetRowsWithoutHitches() { fling("down:fast", up: false) }
    @MainActor func testUpFlingsMeetRowsWithoutHitches() { fling("up:fast", up: true) }

    @MainActor
    private func fling(_ lab: String, up: Bool) {
        let app = launch(lab)
        XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 10))
        let list = app.collectionViews["lab.list"]
        for _ in 0..<10 {
            if up { list.swipeDown(velocity: .fast) } else { list.swipeUp(velocity: .fast) }
        }
        // The last fling comes to rest (its frame window closes).
        settle(list.cells.firstMatch)
        let stats = hud(app)
        record("fling-\(lab)", (app.staticTexts["lab.hud"].value as? String ?? "{}"))
        attach(app, lab.replacingOccurrences(of: ":", with: "-") + "-after-flings")
        XCTAssertGreaterThan(stats.rows, 90, "flings did not read ahead (\(stats.rows) rows)")
        XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "a page moved the reader by \(stats.maxShift) pt")
        XCTAssertGreaterThan(stats.frames, 30, "no frames counted")
    }

    // MARK: Helpers

    enum Direction { case down, up }

    @MainActor
    private func launch(_ lab: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-paged-lab", lab] + extra
        app.launch()
        return app
    }

    @MainActor
    private func hud(_ app: XCUIApplication) -> PagedLabReading {
        PagedLabReading(app.staticTexts["lab.hud"].value as? String ?? "")
    }

    @MainActor
    private func assertOpensAtNewest(_ app: XCUIApplication) {
        let newest = app.descendants(matching: .any)["lab.row.0"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "no newest row")
        settle(newest)
        // The list's bottom edge: the top of the bars under it (the changes, the measurement line, the composer).
        let floor = PagedLabDriver(app: app, test: self).floor
        XCTAssertLessThanOrEqual(newest.frame.maxY, floor + 1, "the newest row is under the composer")
        XCTAssertGreaterThan(newest.frame.maxY, floor - 60, "the list did not open at its newest row")
        attach(app, "up-opens-at-newest")
    }

    /// Scrolls toward the paging edge with held drags (no fling) until the next page is being read,
    /// then holds still while it lands, twice: the row in view keeps its frame to half a point.
    @MainActor
    private func assertPagesLandInPlace(_ app: XCUIApplication, direction: Direction, name: String) {
        XCTAssertTrue(app.descendants(matching: .any)["lab.row.0"].waitForExistence(timeout: 15))
        for landing in 1...2 {
            let target = 30 * (landing + 1)
            // The next page is asked for two screens before the edge: scroll until it is being read.
            var drags = 0
            var now = hud(app)
            while now.rows < target, now.edge != "loading", drags < 80 {
                drag(app, by: direction == .down ? -420 : 420)
                drags += 1
                now = hud(app)
            }
            XCTAssertEqual(now.edge, "loading", "page \(landing + 1) was never asked for")
            XCTAssertLessThan(now.rows, target, "page \(landing + 1) landed before the reader held still; slow the lab's source")
            // Every row on screen, from one snapshot before the page lands and one after.
            let before = rowTops(app)
            XCTAssertLessThan(hud(app).rows, target, "page \(landing + 1) landed before the rows were measured")
            attach(app, "\(name)-page\(landing + 1)-before")
            waitFor("page \(landing + 1)", timeout: 20) { self.hud(app).rows >= target }
            settle(app.collectionViews["lab.list"].cells.firstMatch)
            let after = rowTops(app)
            attach(app, "\(name)-page\(landing + 1)-after")
            let common = Set(before.keys).intersection(after.keys)
            XCTAssertFalse(common.isEmpty, "no row on screen both before and after page \(landing + 1)")
            let moved = common.map { abs(after[$0]! - before[$0]!) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(moved, 0.5, "page \(landing + 1) moved the rows being read by \(moved) pt")
            let stats = hud(app)
            record("landing-\(name)-page\(landing + 1)",
                   "{\"case\":\"\(name)\",\"page\":\(landing + 1),\"rowsCompared\":\(common.count),\"outsideShift\":\(moved),\"probeMaxShift\":\(stats.maxShift)}")
            XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "the probe saw the reader move \(stats.maxShift) pt")
        }
    }

    /// The top of every lab row on screen (a row partly under the bars counts), from one snapshot.
    @MainActor
    private func rowTops(_ app: XCUIApplication) -> [String: CGFloat] {
        guard let snapshot = try? app.collectionViews["lab.list"].snapshot() else { return [:] }
        var tops: [String: CGFloat] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("lab.row."), !element.frame.isEmpty { tops[element.identifier] = element.frame.minY }
            element.children.forEach(walk)
        }
        walk(snapshot)
        return tops
    }

    /// The first lab row fully on screen inside the list.
    @MainActor
    private func visibleRow(_ app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["lab.list"]
        let frame = list.frame
        if let snapshot = try? list.snapshot() {
            func rows(_ element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
                (element.identifier.hasPrefix("lab.row.") ? [element] : []) + element.children.flatMap(rows)
            }
            let inView = rows(snapshot).filter { $0.frame.minY > frame.minY + 120 && $0.frame.maxY < frame.maxY - 160 }
            if let pick = inView.first { return app.descendants(matching: .any)[pick.identifier] }
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lab.row.'")).firstMatch
    }

    /// A held drag of `dy` points (negative moves content up: toward the bottom of the list).
    @MainActor
    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let list = app.collectionViews["lab.list"]
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy < 0 ? 0.8 : 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow,
                    thenHoldForDuration: 0.3)
    }

    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) {
        let done = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed, "timed out waiting for \(what)")
    }

    /// Waits until the element's frame stops changing.
    @MainActor
    private func settle(_ element: XCUIElement) {
        var last = element.frame
        var still = 0
        let steady = NSPredicate { _, _ in
            let now = element.frame
            still = now == last ? still + 1 : 0
            last = now
            return still >= 2
        }
        _ = XCTWaiter.wait(for: [expectation(for: steady, evaluatedWith: nil)], timeout: 3)
    }

    /// A measurement: printed, and kept as a named attachment (the fleet evidence keeps attachments).
    @MainActor
    private func record(_ name: String, _ json: String) {
        print("PAGEDLIST \(name) \(json)")
        let note = XCTAttachment(string: json)
        note.name = "PAGEDLIST-\(name)"
        note.lifetime = .keepAlways
        add(note)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
