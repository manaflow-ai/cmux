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
    }

    @MainActor func testUpLiveRowsKeepAReaderAboveInPlace() {
        let app = launch("up:live")
        assertOpensAtNewest(app)
        // Scroll up a screen and hold still: live rows land below the reader and move nothing.
        drag(app, by: 300)
        let row = visibleRow(app)
        let before = row.frame.minY
        let start = hud(app).rows
        waitFor("live rows", timeout: 10) { self.hud(app).rows >= start + 2 }
        settle(row)
        XCTAssertEqual(row.frame.minY, before, accuracy: 0.5, "a live row moved the row being read")
        attach(app, "up-live-reader-above")
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
        print("PAGEDLIST " + (app.staticTexts["lab.hud"].value as? String ?? "{}") + " lab=\(lab)")
        attach(app, lab.replacingOccurrences(of: ":", with: "-") + "-after-flings")
        XCTAssertGreaterThan(stats.rows, 90, "flings did not read ahead (\(stats.rows) rows)")
        XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "a page moved the reader by \(stats.maxShift) pt")
        XCTAssertGreaterThan(stats.frames, 30, "no frames counted")
    }

    // MARK: Helpers

    struct HUD: Decodable {
        var edge: String
        var rows: Int
        var landings: Int
        var maxShift: Double
        var frames: Int
        var hitches: Int
        var dropped: Int
        var worstMs: Double
        var hitchMsPerS: Double
    }

    enum Direction { case down, up }

    @MainActor
    private func launch(_ lab: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-paged-lab", lab] + extra
        app.launch()
        return app
    }

    @MainActor
    private func hud(_ app: XCUIApplication) -> HUD {
        let text = app.staticTexts["lab.hud"].value as? String ?? ""
        guard let data = text.data(using: .utf8), let hud = try? JSONDecoder().decode(HUD.self, from: data) else {
            return HUD(edge: "", rows: 0, landings: 0, maxShift: 0, frames: 0, hitches: 0, dropped: 0, worstMs: 0, hitchMsPerS: 0)
        }
        return hud
    }

    @MainActor
    private func assertOpensAtNewest(_ app: XCUIApplication) {
        let newest = app.descendants(matching: .any)["lab.row.0"]
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "no newest row")
        settle(newest)
        let composer = app.textFields["lab.composer"]
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY + 1, "the newest row is under the composer")
        XCTAssertGreaterThan(newest.frame.maxY, composer.frame.minY - 60, "the list did not open at its newest row")
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
            while hud(app).rows < target, hud(app).edge != "loading", drags < 30 {
                drag(app, by: direction == .down ? -260 : 260)
                drags += 1
            }
            XCTAssertLess(hud(app).rows, target, "page \(landing + 1) landed before the reader held still; slow the lab's source")
            let row = visibleRow(app)
            settle(row)
            let before = row.frame.minY
            attach(app, "\(name)-page\(landing + 1)-before")
            waitFor("page \(landing + 1)", timeout: 15) { self.hud(app).rows >= target }
            settle(row)
            attach(app, "\(name)-page\(landing + 1)-after")
            XCTAssertEqual(row.frame.minY, before, accuracy: 0.5, "page \(landing + 1) moved the row being read (\(row.identifier))")
            let stats = hud(app)
            print("PAGEDLIST {\"case\":\"\(name)\",\"landing\":\(landing + 1),\"outsideShift\":\(abs(row.frame.minY - before)),\"probeMaxShift\":\(stats.maxShift)}")
            XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "the probe saw the reader move \(stats.maxShift) pt")
        }
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
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy < 0 ? 0.75 : 0.25))
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

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
