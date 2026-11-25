import XCTest

/// The tab grid's pane stacks (Aziz's drawing, 2026-11-23: "clicking the v triggers morph that
/// shows all the tabs in that tab's pane via expansion"). A workspace laid out as the drawing
/// (`-cmux-mobile-demo pane-stacks`, DemoDriver): a pane of three (docs in front), a lone
/// terminal, a lone page, and a pane of two. Folded, the grid shows four cards, two of them in
/// glass encasements with a chevron; opening the first shows six. Each state is a screenshot
/// (the artifact's attachments); run with `video` for the morphs frame by frame:
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=PaneStacksUITests --arg video --artifact artifacts/ios-sim/evidence.zip
final class PaneStacksUITests: XCTestCase {
    override func setUp() {
        // Every state is a screenshot: one wrong count must not cost the rest.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testA_LightOpenFoldAndReverse() {
        runDrawing(prefix: "light", dark: false)
    }

    @MainActor
    func testB_DarkOpenFoldAndReverse() {
        runDrawing(prefix: "dark", dark: true)
    }

    /// One pane of three: the grid's lone card, encased; opening it reflows into two columns.
    @MainActor
    func testC_LoneStack() {
        let app = launch("pane-stacks-lone", dark: false)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["3 Tabs"].firstMatch.waitForExistence(timeout: 60), "the 3-tab grid\n\(app.debugDescription)")
        pause(2.0)
        attach("lone-0-folded")
        XCTAssertEqual(chevrons(app).count, 1, "one stack")
        chevrons(app)[0].tap()
        pause(1.4)
        attach("lone-1-open")
        XCTAssertEqual(closeButtons(app).count, 2, "zsh and build get close buttons; docs leads the stack")
        chevrons(app)[0].tap()
        pause(1.4)
        attach("lone-2-folded")
    }

    /// Thirteen more tabs: a pane of eight that opens past the screen, then the grid scrolls with
    /// the chevrons and encasements riding the cards.
    @MainActor
    func testD_ManyTabsScroll() {
        let app = launch("pane-stacks-many", dark: true)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["19 Tabs"].firstMatch.waitForExistence(timeout: 60), "the 19-tab grid\n\(app.debugDescription)")
        pause(2.0)
        attach("many-0-folded")
        XCTAssertEqual(chevrons(app).count, 3, "three stacks")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        pause(1.5)
        attach("many-1-scrolled")
        // The agents pane's chevron, wherever it is now.
        if let agents = chevrons(app).first(where: { $0.label.contains("8 tabs") }) {
            agents.tap()
            pause(1.6)
            attach("many-2-agents-open")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            pause(1.5)
            attach("many-3-agents-open-scrolled")
        } else {
            XCTFail("the Agents pane's chevron\n\(app.debugDescription)")
        }
    }

    // MARK: The drawing

    @MainActor
    private func runDrawing(prefix p: String, dark: Bool) {
        let app = launch("pane-stacks", dark: dark)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["7 Tabs"].firstMatch.waitForExistence(timeout: 60), "the 7-tab grid\n\(app.debugDescription)")
        pause(2.0)
        attach("\(p)-0-folded")
        // Four cards: two stacks (chevrons) and two lone tabs (close buttons).
        XCTAssertEqual(chevrons(app).count, 2, "two stacks\n\(app.debugDescription)")
        XCTAssertEqual(closeButtons(app).count, 2, "server and cmux.com have close buttons")
        let folded = closeCorners(app)

        // Open the first pane: six cards.
        chevrons(app)[0].tap()
        burst("\(p)-1-opening")
        pause(1.0)
        attach("\(p)-2-open")
        XCTAssertEqual(closeButtons(app).count, 4, "zsh, build, server and cmux.com")
        XCTAssertEqual(chevrons(app)[0].value as? String, "Open")

        // Fold it again: the four cards come back to their places.
        chevrons(app)[0].tap()
        burst("\(p)-3-folding")
        pause(1.0)
        attach("\(p)-4-folded-again")
        assertSame(closeCorners(app), folded, "after folding")

        // Reversed mid-flight: open, then fold 120 ms in; it lands folded.
        chevrons(app)[0].tap()
        pause(0.12)
        chevrons(app)[0].tap()
        burst("\(p)-5-reversed")
        pause(1.0)
        attach("\(p)-6-reversed-rest")
        assertSame(closeCorners(app), folded, "after a reversed open")

        // Both open: nine… the second pane's two as well (seven cards).
        chevrons(app)[0].tap()
        pause(1.2)
        chevrons(app)[1].tap()
        pause(1.2)
        attach("\(p)-7-both-open")
        XCTAssertEqual(closeButtons(app).count, 5, "every card but the two stacks' first")

        // A tab inside an open stack opens; back on the grid the stack is still open, that tab in place.
        let build = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'build'")).firstMatch
        XCTAssertTrue(build.waitForExistence(timeout: 5), "build's card\n\(app.debugDescription)")
        build.tap()
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "build's page\n\(app.debugDescription)")
        pause(1.0)
        attach("\(p)-8-build-page")
        tabs.tap()
        pause(1.5)
        attach("\(p)-9-back-on-grid")

        // Fold the first pane while build (not its front) is the active tab: build becomes the front.
        chevrons(app)[0].tap()
        pause(1.2)
        attach("\(p)-10-folded-on-build")
        // The encasement itself also opens and folds: tap its rim below the first card.
        let tapRim = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        if let first = chevrons(app).first {
            // 4 pt below the card's title row, inside the encasement's padding.
            let f = first.frame
            tapRim.withOffset(CGVector(dx: f.midX - 60, dy: f.minY - 3)).tap()
            pause(1.2)
            attach("\(p)-11-rim-tap")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ demo: String, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", demo,
                                "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        return app
    }

    @MainActor
    private func chevrons(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "tabs.stack.chevron").allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    @MainActor
    private func closeButtons(_ app: XCUIApplication) -> [XCUIElement] {
        let screen = app.windows.firstMatch.frame
        return app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .filter { $0.exists && screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    @MainActor
    private func closeCorners(_ app: XCUIApplication) -> [CGPoint] {
        closeButtons(app).map { CGPoint(x: $0.frame.midX.rounded(), y: $0.frame.midY.rounded()) }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    private func assertSame(_ now: [CGPoint], _ before: [CGPoint], _ when: String) {
        XCTAssertEqual(now.count, before.count, "\(when): \(now) was \(before)")
        for (a, b) in zip(now, before) {
            XCTAssertLessThanOrEqual(max(abs(a.x - b.x), abs(a.y - b.y)), 1, "\(when): \(now) was \(before)")
        }
    }

    /// Screenshots as fast as XCUITest takes them through a morph (the video has every frame).
    @MainActor
    private func burst(_ name: String) {
        for i in 0 ..< 4 { attach("\(name)-\(i)") }
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
