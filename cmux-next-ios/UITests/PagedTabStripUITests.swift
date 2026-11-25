import XCTest

/// The paged strip of horizontal tabs (Settings › Horizontal tabs; Conductor's iPhone toolbar):
/// every state and motion of it, captured for frame-by-frame review against the Conductor
/// recording (screens and, with the fleet step's `video`, the whole run). It also checks what
/// it can measure: the active chip is centered on the screen, the strip lists the active tab's
/// pane only, a drag pages one chip and the tab follows, a short drag springs back.
///
/// Mock data: `CMUX_MOBILE_MOCK_STRIP=1` lists `ws-strip`: a pane of six tabs (Well-being check,
/// Ho, Greeting Message, zsh, Swift docs, a long title), a pane of one (server) and a pane of
/// two (tests, git).
final class PagedTabStripUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testStripDark() throws { try run(appearance: "dark") }

    @MainActor
    func testStripLight() throws { try run(appearance: "light") }

    /// Settings › Horizontal tabs off: the address capsule, as before.
    @MainActor
    func testStripOffKeepsTheCapsule() throws { try runOff(appearance: "dark") }

    @MainActor
    func testStripOffLight() throws { try runOff(appearance: "light") }

    /// With the strip off the pages run under the bar too: the agent chat and a terminal.
    @MainActor
    private func runOff(appearance a: String) throws {
        let app = open(appearance: a, strip: false)
        XCTAssertFalse(app.descendants(matching: .any)["tabs.strip"].exists, "no strip with the setting off")
        XCTAssertTrue(app.buttons["Page Menu"].firstMatch.waitForExistence(timeout: 10) || app.buttons["Tabs"].exists)
        pause(1.0)
        shot(app, "\(a)-off-capsule")
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        if tabs.waitForExistence(timeout: 5) { tabs.tap() }
        pause(1.2)
        let zsh = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'zsh'")).firstMatch
        if zsh.waitForExistence(timeout: 5), zsh.isHittable { zsh.tap() }
        pause(1.2)
        shot(app, "\(a)-off-terminal")
        assertNoSeam(app, below: 140, "\(a) terminal, strip off")
    }

    @MainActor
    private func run(appearance a: String) throws {
        let app = open(appearance: a, strip: true)
        let strip = app.descendants(matching: .any)["tabs.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 15), "strip\n\(app.debugDescription)")
        pause(1.0)
        report(app, "\(a)-rest-first")
        shot(app, "\(a)-01-rest-first")
        assertNoSeam(app, below: strip.frame.maxY + 40, "\(a) agent chat, strip on")
        XCTAssertEqual(chipIDs(app), ["t-strip-wellbeing", "t-strip-ho", "t-strip-greeting", "t-strip-zsh", "t-strip-docs",
                                      "t-strip-long"], "the strip lists the first pane's tabs only")
        assertCentered(app, "t-strip-wellbeing")

        // A slow drag, held half way: both pages show, side by side.
        let y = strip.frame.midY
        let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: y))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -35, dy: 0)),
                     withVelocity: 120, thenHoldForDuration: 0.6)
        report(app, "\(a)-after-short-drag")
        // Released at 35 pt (well under half a chip, slowly): it springs back.
        pause(0.8)
        shot(app, "\(a)-02-short-drag-springs-back")
        assertActive(app, "t-strip-wellbeing", "a short slow drag springs back")

        // A drag past the middle: the next tab.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -150, dy: 0)),
                     withVelocity: 300, thenHoldForDuration: 0.3)
        pause(0.9)
        shot(app, "\(a)-03-paged-to-ho")
        assertActive(app, "t-strip-ho", "a drag past half a chip pages")
        assertCentered(app, "t-strip-ho")

        // A fling: one page, never more.
        center.press(forDuration: 0.02, thenDragTo: center.withOffset(CGVector(dx: -120, dy: 0)),
                     withVelocity: 2500, thenHoldForDuration: 0)
        pause(1.0)
        shot(app, "\(a)-04-fling-one-page")
        assertActive(app, "t-strip-greeting", "a fling pages exactly one chip")

        // A tap on a neighbor chip: the strip and the page slide to it.
        let zsh = app.buttons["tabs.strip.chip.t-strip-zsh"]
        // Partly under the strip's trailing fade: tap its visible leading edge, as a person would.
        if zsh.waitForExistence(timeout: 5) { zsh.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap() }
        print("CMUX_STRIP_TAP zsh=\(zsh.frame) strip=\(strip.frame)")
        pause(1.0)
        print("CMUX_STRIP_TRACE \(strip.value as? String ?? "-")")
        report(app, "\(a)-after-tap")
        shot(app, "\(a)-05-tap-neighbor")
        assertNoSeam(app, below: strip.frame.maxY + 40, "\(a) terminal, strip on")
        assertActive(app, "t-strip-zsh", "a tapped chip becomes the tab")

        // Back toward the start: a drag right.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 150, dy: 0)),
                     withVelocity: 300, thenHoldForDuration: 0.2)
        pause(1.0)
        print("CMUX_STRIP_TRACE_BACK \(strip.value as? String ?? "-")")
        shot(app, "\(a)-06-paged-back")
        assertActive(app, "t-strip-greeting", "a drag right pages back")

        // Out to the last tab (the long title, truncated) and the New Tab chip after it.
        for expected in ["t-strip-zsh", "t-strip-docs", "t-strip-long"] {
            center.press(forDuration: 0.02, thenDragTo: center.withOffset(CGVector(dx: -120, dy: 0)),
                         withVelocity: 2000, thenHoldForDuration: 0)
            pause(0.9)
            print("CMUX_STRIP_TRACE_FLING \(expected) \(strip.value as? String ?? "-") active=\(activeID(app) ?? "-")")
            assertActive(app, expected, "each fling pages one chip")
        }
        shot(app, "\(a)-07-long-title")
        assertActive(app, "t-strip-long", "three flings reach the last tab")
        report(app, "\(a)-long")

        // The active chip opens the page menu.
        let active = app.buttons["tabs.strip.chip.t-strip-long"]
        if active.isHittable { active.tap() }
        pause(1.0)
        shot(app, "\(a)-08-active-chip-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        pause(0.8)

        // The grid: a tab of another pane shows that pane's strip.
        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        if tabs.waitForExistence(timeout: 5) { tabs.tap() }
        pause(1.2)
        shot(app, "\(a)-09-grid")
        let server = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'server'")).firstMatch
        if server.waitForExistence(timeout: 5), server.isHittable { server.tap() }
        pause(1.2)
        shot(app, "\(a)-10-one-tab-pane")
        report(app, "\(a)-one-tab-pane")
        XCTAssertEqual(chipIDs(app), ["t-strip-solo"], "a pane of one lists one chip")
        assertCentered(app, "t-strip-solo")

        if tabs.waitForExistence(timeout: 5) { tabs.tap() }
        pause(1.2)
        let tests = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'tests'")).firstMatch
        if tests.waitForExistence(timeout: 5), tests.isHittable { tests.tap() }
        pause(1.2)
        shot(app, "\(a)-11-two-tab-pane")
        XCTAssertEqual(chipIDs(app), ["t-strip-tests", "t-strip-git"], "the third pane's two tabs")

        // Rubber band at the first chip: a drag right past it returns.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 120, dy: 0)),
                     withVelocity: 200, thenHoldForDuration: 0.4)
        pause(0.9)
        shot(app, "\(a)-12-rubber-band-returns")
        assertActive(app, "t-strip-tests", "the first chip stays after a drag right")
    }

    // MARK: Helpers

    @MainActor
    private func open(appearance: String, strip: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_STRIP"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.appearance", appearance,
                                "-cmuxMobile.settings.horizontalTabs", strip ? "<true/>" : "<false/>"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-strip"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()
        _ = app.descendants(matching: .any)["workspace.ws-strip"].waitForExistence(timeout: 15)
        return app
    }

    private func chipIDs(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.strip.chip.'")).allElementsBoundByIndex
            .map { $0.identifier.replacingOccurrences(of: "tabs.strip.chip.", with: "") }
    }

    private func activeID(_ app: XCUIApplication) -> String? {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.strip.chip.'")).allElementsBoundByIndex
            .first { $0.isSelected }?.identifier.replacingOccurrences(of: "tabs.strip.chip.", with: "")
    }

    private func assertActive(_ app: XCUIApplication, _ id: String, _ message: String) {
        XCTAssertEqual(activeID(app), id, message)
    }

    /// The active chip's center is the screen's, within a point.
    private func assertCentered(_ app: XCUIApplication, _ id: String) {
        let chip = app.buttons["tabs.strip.chip.\(id)"]
        guard chip.exists else { return XCTFail("chip \(id) missing") }
        XCTAssertEqual(chip.frame.midX, app.frame.midX, accuracy: 1, "\(id) centered: \(chip.frame)")
    }

    /// Every chip's frame, for the report's measurements.
    private func report(_ app: XCUIApplication, _ label: String) {
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.strip.'")).allElementsBoundByIndex
        let frames = chips.map { "\($0.identifier)=\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))\($0.isSelected ? "*" : "")" }
        let back = app.buttons["Back"].firstMatch
        print("CMUX_STRIP \(label) screen=\(Int(app.frame.width)) back=\(back.exists ? "\(back.frame)" : "none") \(frames.joined(separator: " "))")
    }

    /// The page's background runs up under the bar to the top of the screen: the color at the
    /// very top (beside the status bar's clock and icons) is the page's own color below the bar.
    private func assertNoSeam(_ app: XCUIApplication, below y: CGFloat, _ label: String) {
        let image = app.screenshot().image
        let top = pixel(image, at: CGPoint(x: app.frame.midX, y: 2))
        let page = pixel(image, at: CGPoint(x: app.frame.maxX - 3, y: y))
        print("CMUX_STRIP_SEAM \(label) top=\(top) page=\(page) y=\(Int(y))")
        guard let top, let page else { return XCTFail("\(label): no pixels") }
        let delta = zip(top, page).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(delta, 12, "\(label): the top of the screen \(top) is not the page's color \(page)")
    }

    /// One pixel's RGB at a point of `image` (points, top-left origin).
    private func pixel(_ image: UIImage, at p: CGPoint) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let x = Int(p.x * image.scale), y = Int(p.y * image.scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The pixel at (x, y) from the top lands on the 1x1 context.
            ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? Array(data[0..<3]) : nil
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        // Wall clock of the shot, to find it in the step's screen recording (ui-video-start.txt).
        print("CMUX_STRIP_SHOT \(name) t=\(String(format: "%.3f", Date().timeIntervalSince1970))")
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "strip-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
