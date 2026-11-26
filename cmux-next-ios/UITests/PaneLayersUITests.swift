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

    // MARK: The cached frame

    /// Leo, 2026-11-24: "the served cached thing included the gap induced by my built-in keyboard,
    /// and i couldnt interact with it stil." `-CmuxMobileColdFrameDemo` serves every mock terminal
    /// a cached still taken keyboard-up (rows end at 45% of the screen) and never attaches. With
    /// the keyboard down the still's last row rests on the key row, not mid screen, and the
    /// composer takes a tap and typing at once; keyboard up, the rows ride above the dock.
    @MainActor
    func testCachedFrameFillsViewportAndTakesInput() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle",
                                "-CmuxMobileColdFrameDemo"]
        app.launch()
        let field = app.textViews["terminal.composer.field"]
        let keyRow = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "composer\n\(app.debugDescription)")
        XCTAssertTrue(keyRow.waitForExistence(timeout: 10), "key row")
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        attach(app, "cold-1-keyboard-down")

        let downGap = gapAboveDock(app, dockTop: min(keyRow.frame.minY, field.frame.minY))
        print("CMUX_COLD_FRAME keyboard-down gap=\(downGap.map { String(Int($0)) } ?? "none")")
        XCTAssertNotNil(downGap, "no cached rows drawn above the dock")
        XCTAssertLessThanOrEqual(downGap ?? .greatestFiniteMagnitude, 60,
                                 "the cached still's last row sits \(Int(downGap ?? -1)) pt above the dock: the keyboard gap it was taken with")

        // Interactive at once: the composer takes the tap and the keys, over the cached still.
        XCTAssertTrue(field.isHittable, "the composer is under the cached still")
        field.tap()
        field.typeText("ls")
        XCTAssertTrue((field.value as? String ?? "").contains("ls"), "typing reached the composer (\(field.value ?? "nil"))")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        attach(app, "cold-2-keyboard-up")
        let upGap = gapAboveDock(app, dockTop: min(keyRow.frame.minY, field.frame.minY))
        print("CMUX_COLD_FRAME keyboard-up gap=\(upGap.map { String(Int($0)) } ?? "none")")
        XCTAssertLessThanOrEqual(upGap ?? .greatestFiniteMagnitude, 60, "keyboard up: the rows end on the dock")

        // Keyboard down again: the still reflows back onto the dock.
        if keyRow.isHittable { keyRow.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attach(app, "cold-3-keyboard-down-again")
        let againGap = gapAboveDock(app, dockTop: min(keyRow.frame.minY, field.frame.minY))
        print("CMUX_COLD_FRAME keyboard-down-again gap=\(againGap.map { String(Int($0)) } ?? "none")")
        XCTAssertLessThanOrEqual(againGap ?? .greatestFiniteMagnitude, 60, "keyboard down again: the rows end on the dock")
    }

    /// Points between the dock's top and the lowest bright (text) pixel row above it, read from a
    /// screenshot, in the page's text column. Nil: no bright row between mid-top and the dock.
    @MainActor
    func gapAboveDock(_ app: XCUIApplication, dockTop: CGFloat) -> CGFloat? {
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        let scale = CGFloat(height) / max(1, app.frame.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let start = Int((dockTop - 3) * scale)
        let stop = Int(CGFloat(height) * 0.12)
        let x0 = Int(8 * scale), x1 = Int(CGFloat(width) * 0.7)
        var y = min(height - 1, start)
        while y > stop {
            // The bitmap's first row is the image's top row.
            let row = y * width * 4
            var x = x0
            while x < x1 {
                let o = row + x * 4
                if pixels[o] > 200, pixels[o + 1] > 200, pixels[o + 2] > 200 { return dockTop - CGFloat(y) / scale }
                x += 1
            }
            y -= 1
        }
        return nil
    }
}
