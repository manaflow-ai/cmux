import XCTest

/// Leo, 2026-11-12: "does the iPhone now, like, just do the projection? Like
/// it calculates it itself and it's all, like, identical, or I mean, like,
/// better than before maybe?" and "when i load in it show me uncompact then
/// squish well iphone should do more work it lazy relaxing!?"
///
/// The terminal demo's `projection` phase: a shell on a Mac pane of 120x40
/// (`MacPaneMockSession`, "Fit the smallest viewer"), through the session the
/// app builds for a Mac terminal, on the real terminal page. The demo shows
/// and hides the keyboard; this test then switches to the home screen and
/// back, and rotates the phone to landscape and back. The demo's label keeps
/// `p.<stage>.mac<Mac PTY resizes>.wide<wide grids>.rs<mirror resets>`.
/// Each action's counts are printed (`projection ui:` lines) for the PR's
/// table, and none may resize the Mac or show the Mac's wide grid.
final class TerminalProjectionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private struct Counts: Equatable, CustomStringConvertible {
        var mac = 0
        var wide = 0
        var resets = 0
        var description: String { "mac PTY resizes \(mac), wide grids \(wide), resets \(resets)" }
        static func - (a: Counts, b: Counts) -> Counts { Counts(mac: a.mac - b.mac, wide: a.wide - b.wide, resets: a.resets - b.resets) }
    }

    private func counts(_ label: String) -> Counts? {
        // p.<stage>.mac<n>.wide<n>.rs<n>
        var out = Counts()
        var found = 0
        for part in label.split(separator: ".") {
            if part.hasPrefix("mac"), let n = Int(part.dropFirst(3)) { out.mac = n; found += 1 }
            if part.hasPrefix("wide"), let n = Int(part.dropFirst(4)) { out.wide = n; found += 1 }
            if part.hasPrefix("rs"), let n = Int(part.dropFirst(2)) { out.resets = n; found += 1 }
        }
        return found == 3 ? out : nil
    }

    @MainActor
    func testPrimaryScreenNeverResizesTheMac() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "projection"]
        app.launch()
        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        func wait(for stage: String, timeout: TimeInterval = 60) -> Counts? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let label = probe.label
                if label.hasPrefix("p.\(stage)."), let counts = counts(label) { return counts }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return nil
        }
        func now() -> Counts? {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            return counts(probe.label)
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var rows: [(String, Counts)] = []
        guard let attached = wait(for: "kbstart") else { return XCTFail("the demo never attached: \(probe.label)") }
        rows.append(("attach", attached))
        shot("attached")
        guard let keyboard = wait(for: "kb") else { return XCTFail("the keyboard toggles never ended: \(probe.label)") }
        rows.append(("keyboard show and hide", keyboard - attached))
        guard var last = wait(for: "live") else { return XCTFail("no live counts: \(probe.label)") }

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.activate()
        _ = probe.waitForExistence(timeout: 10)
        if let back = now() {
            rows.append(("app switch (3 s)", back - last))
            last = back
        }
        shot("back-from-home")

        XCUIDevice.shared.orientation = .landscapeLeft
        if let turned = now() {
            rows.append(("rotate to landscape", turned - last))
            last = turned
        }
        shot("landscape")
        XCUIDevice.shared.orientation = .portrait
        if let back = now() {
            rows.append(("rotate back", back - last))
            last = back
        }
        shot("portrait-again")

        for (name, counts) in rows {
            print("projection ui: \(name): \(counts)")
            XCTContext.runActivity(named: "\(name): \(counts)") { _ in }
        }
        for (name, counts) in rows {
            XCTAssertEqual(counts.mac, 0, "\(name) resized the Mac's PTY (\(counts))")
            XCTAssertEqual(counts.wide, 0, "\(name) drew the Mac's wide grid on the phone (\(counts))")
        }
    }
}
