import XCTest

/// Leo, 2026-11-14: "is there a way to do it and like maintain expected
/// behavior while not needing to f***ing stream the literal f***ing Mac
/// screen on the f***ing phone?" The phone holds a window of a Mac
/// terminal's long history, never all of it, and a reader still scrolls to
/// line 1 and back down to the newest rows.
///
/// Runs the DEBUG `-CmuxMobileHistoryWindowDemo` screen: the real
/// `DaemonTerminalSession`, terminal screen and Ghostty, against a fake Mac
/// whose terminal holds 30,000 numbered history rows and answers as cmux-tui
/// does for `attach-replay-history-window-v1`. Its caption
/// (`terminal.historyDemo.state`) says what the mirror holds.
final class TerminalHistoryWindowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private struct State {
        var omitted = -1
        var window: Int?
        var skipped = -1
        var fetches = 0
        /// Window fetches that moved the window toward the screen.
        var down = 0
        var maxHeld = 0
        var of = 0
        /// The first word of the page's first row with text when it last came
        /// to rest: a demo row's number (`TerminalHistoryWindowProbe`).
        var top = ""
    }

    @MainActor
    func testScrollToLineOneAndBackToTheNewestRows() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CmuxMobileHistoryWindowDemo", "-CmuxMobileHistoryWindowDemoRows", "30000"]
        app.launch()
        let caption = app.staticTexts["terminal.historyDemo.state"]
        XCTAssertTrue(caption.waitForExistence(timeout: 30), "the demo's caption\n\(app.debugDescription)")
        XCTAssertTrue(wait(caption, timeout: 30) { $0.fetches >= 1 && $0.of == 30_000 }, "attached: \(caption.label)")
        XCTAssertEqual(state(caption).omitted, 30_000, "the attach is the screen alone: \(caption.label)")
        attach(app, "1-attached-screen-only")

        // Up to line 1: each fling that nears the oldest row held fetches older rows.
        var drags = 0
        // The caption (its probe trail too) when a window first fell back to
        // the newest rows on the way up.
        var fellBack: String?
        var windowed = false
        while state(caption).omitted > 0, drags < 600 {
            fling(app, from: 0.2, to: 0.7)
            drags += 1
            let now = state(caption)
            if now.window != nil { windowed = true } else if windowed, fellBack == nil {
                fellBack = "after \(drags) drags: \(caption.label)"
                attach(app, "2-fell-back-\(drags)")
            }
            if drags % 40 == 0 { attach(app, "2-scrolling-up-\(drags)") }
        }
        let top = state(caption)
        XCTAssertEqual(top.omitted, 0, "line 1 reached after \(drags) drags: \(caption.label); first fall back to the newest rows: \(fellBack ?? "none")")
        XCTAssertNil(fellBack, "going up, the window never fell back to the newest rows")
        XCTAssertEqual(top.window, 0, "the mirror holds a window from line 1: \(caption.label)")
        XCTAssertGreaterThan(top.skipped, 0, "the rows between the window and the screen stay on the Mac: \(caption.label)")
        XCTAssertLessThanOrEqual(top.maxHeld, 10_000, "no replay held more than 10,000 of the 30,000 rows: \(caption.label)")
        // Going up never moves the window back down (run 8f9f55310f87a97be78b36cd:
        // 40 steps down on the way up, 98 fetches, the page left on the Mac's screen).
        XCTAssertEqual(top.down, 0, "going up never moved the window toward the screen: \(caption.label)")
        // The page's very top: row 000000. The reader rests on their own rows
        // after the last fetch, a window step (1,500 rows) below line 1, a
        // few flings of the rows held. Read from the page's own rows, not the
        // caption's numbers: at 77fee684 (step 8f9f55310f87a97be78b36cd) the
        // numbers passed while the page showed the Mac's screen.
        var topFlings = 0
        while !wait(caption, timeout: 2, { $0.top == "000000" }), topFlings < 40 {
            fling(app, from: 0.2, to: 0.7)
            topFlings += 1
        }
        XCTAssertEqual(state(caption).top, "000000", "the page rests on line 1 after \(topFlings) more flings: \(caption.label)")
        XCTAssertEqual(state(caption).omitted, 0, "no row above line 1: \(caption.label)")
        attach(app, "3-line-1")

        // Back down: reaching the window's end moves it toward the screen.
        // Read from the fake Mac's side (`down`: window fetches whose first
        // row is nearer the screen than the one before), not the caption's
        // window, which one fling can carry past every step to the tail
        // between two reads. Without `loadNewerHistory` from the scroll this
        // stays 0 and the test fails here.
        drags = 0
        while state(caption).down == 0, drags < 200 {
            fling(app, from: 0.7, to: 0.2)
            drags += 1
        }
        let down = state(caption)
        XCTAssertGreaterThan(down.down, 0, "coming down moves the window toward the screen after \(drags) drags: \(caption.label)")
        XCTAssertLessThanOrEqual(down.maxHeld, 10_000, "no replay on the way down held more than 10,000 rows: \(caption.label)")
        attach(app, "4-window-moved-down")

        // To the screen, then up from it: the newest rows come back, contiguous.
        let jump = app.buttons["terminal.jumpToBottom"]
        if jump.waitForExistence(timeout: 3) {
            jump.tap()
        } else {
            for _ in 0..<40 where state(caption).window != nil { fling(app, from: 0.7, to: 0.2) }
        }
        attach(app, "5-the-screen")
        drags = 0
        while state(caption).window != nil || state(caption).skipped != 0, drags < 20 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            drags += 1
            _ = wait(caption, timeout: 1) { $0.window == nil && $0.skipped == 0 }
        }
        let newest = state(caption)
        XCTAssertNil(newest.window, "the mirror holds the newest rows again: \(caption.label)")
        XCTAssertEqual(newest.skipped, 0, "its rows reach the Mac's screen: \(caption.label)")
        // The newest rows: at most 10,000 of them (the tail's cap), and some.
        // Their count depends on how it got there: up from the screen asks
        // for 10,000; the window stepping down to within its size of the
        // screen keeps the rows from its start (at most twice the window).
        XCTAssertLessThan(newest.omitted, 30_000, "the mirror holds history rows: \(caption.label)")
        XCTAssertLessThanOrEqual(30_000 - newest.omitted, 10_000, "at most the newest 10,000 rows: \(caption.label)")
        XCTAssertLessThanOrEqual(newest.maxHeld, 10_000, "no replay held more than 10,000 rows: \(caption.label)")
        attach(app, "6-newest-rows")
        print("HISTORY-WINDOW-UI final: \(caption.label)")
    }

    /// A fast drag between two heights, so the page flings on past the finger.
    @MainActor
    private func fling(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: XCUIGestureVelocity(20_000), thenHoldForDuration: 0)
        // The fling runs out and any fetch's replay lands.
        Thread.sleep(forTimeInterval: 0.4)
    }

    @MainActor
    private func state(_ caption: XCUIElement) -> State {
        var state = State()
        for field in caption.label.split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let value = Int(pair[1])
            switch pair[0] {
            case "omitted": state.omitted = value ?? -1
            case "window": state.window = value
            case "skipped": state.skipped = value ?? -1
            case "fetches": state.fetches = value ?? 0
            case "down": state.down = value ?? 0
            case "maxHeld": state.maxHeld = value ?? 0
            case "of": state.of = value ?? 0
            case "top": state.top = String(pair[1])
            default: break
            }
        }
        return state
    }

    @MainActor
    private func wait(_ caption: XCUIElement, timeout: TimeInterval, _ condition: (State) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition(state(caption)) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition(state(caption))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
