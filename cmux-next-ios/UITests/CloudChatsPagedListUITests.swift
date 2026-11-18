import XCTest

/// A Cloud machine's chats on the shared infinite-scroll list (`PagedList`, verify/paged-list.md),
/// in their DEBUG gallery (`-cmux-mobile-paged-screen cloudchats:SCENARIO`, `CloudChatsGallery`):
/// older chats land as the reader nears the end without moving any row on screen (measured from
/// outside, every row's frame, and inside, the list's probe); a chat that runs again moves to the
/// top without moving the reader; flings meet rows with no hitches (CLOUDCHATS lines); and every
/// state shows: connecting, connect failed and Retry, empty, the end spinning while older chats are
/// read, the read stopped and Try Again, and the end.
final class CloudChatsPagedListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Pages land, the reader's rows stay

    @MainActor func testCloudChatsPageLandsWithoutMovingTheReader() {
        assertPagesLandInPlace(launch("cloudchats:slow"), name: "cloudchats")
    }

    @MainActor func testCloudChatsPageLandsWithoutMovingTheReaderAtAccessibilityTextSize() {
        let app = launch("cloudchats:slow", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        assertPagesLandInPlace(app, name: "cloudchats-ax")
    }

    /// Chats above the reader that run again move to the top: the rows being read stay.
    @MainActor func testCloudChatsChatMovingToTheTopKeepsTheReaderInPlace() {
        let app = launch("cloudchats:live")
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "no chats")
        // Rows cc-5 to cc-7 go above the reader's top.
        for _ in 0..<3 { drag(app, by: -420) }
        settle(list(app).cells.firstMatch)
        let before = rowTops(app)
        XCTAssertNil(before["cloudChats.row.cc-5"].flatMap { $0 > list(app).frame.minY ? $0 : nil },
                     "cc-5 is still on screen: scroll further before bumping")
        attach(app, "cloudchats-live-before")
        for _ in 0..<3 { app.buttons["lab.bump"].tap() }
        settle(list(app).cells.firstMatch)
        let after = rowTops(app)
        attach(app, "cloudchats-live-after")
        let moved = ["cloudChats.row.cc-5", "cloudChats.row.cc-6", "cloudChats.row.cc-7"]
        let common = Set(before.keys).intersection(after.keys).subtracting(moved)
        XCTAssertFalse(common.isEmpty, "no row on screen both before and after the moves")
        let shift = common.map { abs(after[$0]! - before[$0]!) }.max() ?? .infinity
        let stats = hud(app)
        record("live-move", #"{"rowsCompared":\#(common.count),"outsideShift":\#(shift),"probeMaxShift":\#(stats.maxShift)}"#)
        XCTAssertLessThanOrEqual(shift, 0.5, "chats moving to the top moved the rows being read by \(shift) pt")
    }

    // MARK: Flings

    @MainActor func testCloudChatsFlingsMeetRowsWithoutHitches() {
        let app = launch("cloudchats:fast")
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "no chats")
        // Pages of 100 land during the flings (600 chats; one page shows at first).
        for _ in 0..<20 { list(app).swipeUp(velocity: .fast) }
        // The last fling comes to rest (its frame window closes).
        settle(list(app).cells.firstMatch)
        let stats = hud(app)
        record("fling", app.staticTexts["lab.hud"].value as? String ?? "{}")
        record("fling-hitches", app.staticTexts["lab.hitches"].value as? String ?? "[]")
        attach(app, "cloudchats-after-flings")
        XCTAssertGreaterThanOrEqual(stats.rows, 300, "flings did not show older pages (\(stats.rows) rows)")
        XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "a page moved the reader by \(stats.maxShift) pt")
        XCTAssertGreaterThan(stats.frames, 30, "no frames counted")
        XCTAssertEqual(stats.hitches, 0, "flings hitched (\(stats.hitches) of \(stats.frames) frames, worst \(stats.worstMs) ms)")
    }

    // MARK: States

    @MainActor func testCloudChatsConnecting() {
        let app = launch("cloudchats:connecting")
        XCTAssertTrue(app.descendants(matching: .any)["cloudChats.connecting"].waitForExistence(timeout: 5), "no connecting state")
        attach(app, "cloudchats-connecting")
    }

    @MainActor func testCloudChatsConnectFailureThenRetry() {
        let app = launch("cloudchats:connectfail")
        let failed = app.descendants(matching: .any)["cloudChats.connectFailed"]
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "no connect failure state")
        attach(app, "cloudchats-connect-failed")
        let retry = failed.buttons.firstMatch.exists ? failed.buttons.firstMatch : app.buttons["Retry"]
        retry.tap()
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "Retry did not load chats")
        attach(app, "cloudchats-connect-recovered")
    }

    @MainActor func testCloudChatsEmpty() {
        let app = launch("cloudchats:empty")
        XCTAssertTrue(app.descendants(matching: .any)["cloudChats.list.empty"].waitForExistence(timeout: 10), "no empty state")
        attach(app, "cloudchats-empty")
    }

    /// While the hub still reads older chats, the end spins (never a button to tap).
    @MainActor func testCloudChatsEndSpinsWhileOlderChatsAreRead() {
        let app = launch("cloudchats:slow")
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "no chats")
        let loading = edge(app, "loading")
        for _ in 0..<12 where !(loading.exists && loading.isHittable) { list(app).swipeUp(velocity: .fast) }
        XCTAssertTrue(loading.waitForExistence(timeout: 5), "no spinning end")
        XCTAssertFalse(app.buttons["cloudChats.more"].exists, "Show Older Chats is still there")
        attach(app, "cloudchats-edge-loading")
    }

    @MainActor func testCloudChatsStoppedReadThenTryAgain() {
        let app = launch("cloudchats:reststop")
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "no chats")
        let failed = edge(app, "failed")
        for _ in 0..<12 where !(failed.exists && failed.isHittable) { list(app).swipeUp(velocity: .fast) }
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "the end did not offer Try Again")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a stopped read shows an alert")
        attach(app, "cloudchats-edge-failed")
        app.buttons["cloudChats.list.retry"].tap()
        // The reconnect reads every chat; the list keeps the chats shown, and older ones follow.
        let older = row(app, 150)
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10) || app.cells.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<16 where !older.exists { list(app).swipeUp(velocity: .fast) }
        XCTAssertTrue(older.waitForExistence(timeout: 5), "Try Again did not bring the older chats")
        attach(app, "cloudchats-edge-recovered")
    }

    @MainActor func testCloudChatsEndOfList() {
        let app = launch("cloudchats:end")
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 10), "no chats")
        let last = row(app, 149)
        for _ in 0..<16 where !(last.exists && last.isHittable) { list(app).swipeUp(velocity: .fast) }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "the last chat did not show")
        XCTAssertFalse(edge(app, "more").exists || edge(app, "loading").exists, "the list did not end after its last chat")
        XCTAssertFalse(row(app, 150).exists, "a chat past the end")
        attach(app, "cloudchats-end")
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

    @MainActor
    private func launch(_ lab: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-paged-screen", lab] + extra
        app.launch()
        return app
    }

    @MainActor private func list(_ app: XCUIApplication) -> XCUIElement { app.collectionViews["cloudChats.list"] }
    @MainActor private func row(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
        app.descendants(matching: .any)["cloudChats.row.cc-\(n)"]
    }
    @MainActor private func edge(_ app: XCUIApplication, _ state: String) -> XCUIElement {
        app.descendants(matching: .any)["cloudChats.list.edge.\(state)"]
    }

    @MainActor
    private func hud(_ app: XCUIApplication) -> HUD {
        let text = app.staticTexts["lab.hud"].value as? String ?? ""
        guard let data = text.data(using: .utf8), let hud = try? JSONDecoder().decode(HUD.self, from: data) else {
            return HUD(edge: "", rows: 0, landings: 0, maxShift: 0, frames: 0, hitches: 0, dropped: 0, worstMs: 0, hitchMsPerS: 0)
        }
        return hud
    }

    /// Scrolls with held drags (no fling) until the spinning end is on screen, holds still, hands
    /// the list the hub's next 100 chats (`lab.deliver`), and compares every row on screen before
    /// and after they land, twice: 200, then 300 chats.
    @MainActor
    private func assertPagesLandInPlace(_ app: XCUIApplication, name: String) {
        XCTAssertTrue(row(app, 0).waitForExistence(timeout: 15), "no chats")
        for landing in 1...2 {
            let target = 100 * (landing + 1)
            let spinning = edge(app, "loading")
            var drags = 0
            while !(spinning.exists && spinning.isHittable), drags < 120 {
                drag(app, by: -420)
                drags += 1
            }
            XCTAssertTrue(spinning.exists, "the end never came into view before page \(landing + 1)")
            // Back off a little so rows fill the screen above the end.
            drag(app, by: 200)
            settle(list(app).cells.firstMatch)
            let before = rowTops(app)
            attach(app, "\(name)-page\(landing + 1)-before")
            app.buttons["lab.deliver"].tap()
            waitFor("page \(landing + 1)", timeout: 10) { self.hud(app).rows >= target }
            settle(list(app).cells.firstMatch)
            let after = rowTops(app)
            attach(app, "\(name)-page\(landing + 1)-after")
            let common = Set(before.keys).intersection(after.keys)
            XCTAssertFalse(common.isEmpty, "no row on screen both before and after page \(landing + 1)")
            let moved = common.map { abs(after[$0]! - before[$0]!) }.max() ?? .infinity
            let stats = hud(app)
            record("landing-\(name)-page\(landing + 1)",
                   #"{"case":"\#(name)","page":\#(landing + 1),"rowsCompared":\#(common.count),"outsideShift":\#(moved),"probeMaxShift":\#(stats.maxShift)}"#)
            XCTAssertLessThanOrEqual(moved, 0.5, "page \(landing + 1) moved the rows being read by \(moved) pt")
            XCTAssertLessThanOrEqual(stats.maxShift, 0.5, "the probe saw the reader move \(stats.maxShift) pt")
        }
    }

    /// The top of every chat row on screen, from one snapshot.
    @MainActor
    private func rowTops(_ app: XCUIApplication) -> [String: CGFloat] {
        guard let snapshot = try? list(app).snapshot() else { return [:] }
        var tops: [String: CGFloat] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("cloudChats.row."), !element.frame.isEmpty { tops[element.identifier] = element.frame.minY }
            element.children.forEach(walk)
        }
        walk(snapshot)
        return tops
    }

    /// A held drag of `dy` points (negative moves content up: toward the end of the list).
    @MainActor
    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let start = list(app).coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: dy < 0 ? 0.75 : 0.2))
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
    private func record(_ name: String, _ json: String) {
        print("CLOUDCHATS \(name) \(json)")
        let note = XCTAttachment(string: json)
        note.name = "CLOUDCHATS-\(name)"
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
