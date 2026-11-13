import XCTest

/// Captures every agent chat row kind and variant from the row gallery
/// (`-cmux-mobile-demo row-gallery`, `MockAgentSession+RowGallery`), opened as
/// the workspace's agent tab: each part paged from the top of its transcript to
/// the bottom, one screenshot per page, attached as `uistate~~<group>~~<part>-pNN~~<look>`
/// (the all-UI-states naming, `UIStateCapture.swift`). Misses never fail the run.
final class AgentRowGalleryCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase

    static let parts = [
        "prompts", "answers", "tools", "edits", "cards", "endings", "earlier",
        "live-permission", "live-question", "live-working", "live-retrying", "live-elevation", "live-streaming",
    ]
    /// Parts with rows that fold (tools, groups, thoughts, the Chief's context, diffs, plans).
    static let foldingParts = ["prompts", "answers", "tools", "edits", "cards", "live-permission", "live-streaming"]

    @MainActor func testCollapsedLight() { run(group: "Rows", parts: Self.parts, look: .light) }
    @MainActor func testCollapsedDark() { run(group: "Rows", parts: Self.parts, look: .dark) }
    @MainActor func testExpanded() {
        for look in Look.allCases { run(group: "Rows expanded", parts: Self.foldingParts, look: look, open: true) }
    }
    @MainActor func testLargeText() {
        run(group: "Rows at accessibility text size", parts: Self.parts, look: .light, largeText: true)
    }

    @MainActor
    private func run(group: String, parts: [String], look: Look, open: Bool = false, largeText: Bool = false) {
        for part in parts {
            XCUIDevice.shared.appearance = look.device
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchEnvironment["CMUX_MOBILE_ROW_GALLERY"] = part
            if open { app.launchEnvironment["CMUX_MOBILE_ROW_GALLERY_OPEN"] = "1" }
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", look.rawValue,
                                    "-cmux-mobile-demo", "row-gallery"]
            if largeText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
            }
            app.launch()
            _ = app.wait(for: .runningForeground, timeout: 20)
            pickTeamIfAsked(app)
            // The chat's header (its More menu) says the transcript is up.
            guard app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 40) else {
                attachShot(group: group, id: "\(part)-p01", look: look, miss: "the agent chat did not open")
                app.terminate()
                continue
            }
            C.pause(2.5)
            page(app, group: group, part: part, look: look)
            app.terminate()
        }
    }

    /// From the top of the transcript to the bottom, a shot per page. A page is the
    /// bottom when its text is the same as the page before it.
    @MainActor
    private func page(_ app: XCUIApplication, group: String, part: String, look: Look) {
        var last: [Int] = visibleText(app)
        for _ in 0..<40 {
            drag(app, down: true)
            let now = visibleText(app)
            if now == last { break }
            last = now
        }
        C.pause(0.8)
        var index = 1
        attachShot(group: group, id: String(format: "%@-p%02d", part, index), look: look, miss: nil)
        for _ in 0..<40 {
            drag(app, down: false)
            C.pause(0.7)
            let now = visibleText(app)
            if now == last { break }
            last = now
            index += 1
            attachShot(group: group, id: String(format: "%@-p%02d", part, index), look: look, miss: nil)
        }
    }

    /// A slow drag with no fling, about half a screen, inside the transcript (above the composer).
    @MainActor
    private func drag(_ app: XCUIApplication, down: Bool) {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let (from, to) = down ? (top, bottom) : (bottom, top)
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    /// Where the text on screen sits (one accessibility snapshot), for spotting the end of the
    /// scroll. Positions only: a live timer changes its label, not where it is.
    @MainActor
    private func visibleText(_ app: XCUIApplication) -> [Int] {
        guard let root = try? app.snapshot() else { return [] }
        let window = root.frame
        var out: [Int] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, !node.frame.isEmpty, window.intersects(node.frame) {
                out.append(Int(node.frame.minY))
            }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }
}
