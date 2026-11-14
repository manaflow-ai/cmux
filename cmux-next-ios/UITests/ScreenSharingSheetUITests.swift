import UIKit
import XCTest

/// The Screen Sharing sheet a workspace's + opens (mock data, the simulator in Dark Mode).
///
/// - User 2026-11-05: "Some of the toggles in screen sharing sheet on iOS are white on white."
///   The sheet took the app's neutral `label` tint, and a switch takes its on-track color from the
///   tint: a white track under a white knob in Dark Mode. Its switches must be the app's green.
/// - User 2026-11-05: Screen Sharing opens as a tab, not only as a sheet. Open as Tab closes the
///   sheet and shows a Screen Sharing tab in the workspace, which lists in its tab grid.
final class ScreenSharingSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The reported look: Dark Mode, where the label tint is white (a white track, a white knob).
    @MainActor
    func testViewerSwitchesAreGreenWhenOnInDarkMode() throws {
        try assertViewerSwitchesGreen(appearance: "dark")
    }

    /// Light Mode: the label tint is black, so an on switch read as a black track.
    @MainActor
    func testViewerSwitchesAreGreenWhenOnInLightMode() throws {
        try assertViewerSwitchesGreen(appearance: "light")
    }

    @MainActor
    private func assertViewerSwitchesGreen(appearance: String) throws {
        let app = openSheet(appearance: appearance)
        for name in ["Fit to Display", "Show Stats"] {
            let toggle = app.switches[name].firstMatch
            if !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "\(name) switch\n\(app.debugDescription)")
            if (toggle.value as? String) != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTAssertEqual(toggle.value as? String, "1", "\(name) is on")
        }
        settle(0.8)
        let shot = app.screenshot()
        attach(shot, "screen-sharing-switches-on-\(appearance)")
        for name in ["Fit to Display", "Show Stats"] {
            let frame = app.switches[name].firstMatch.frame
            let green = Self.greenPixels(in: shot.image, trailingOf: frame)
            XCTAssertGreaterThan(green, 200, "\(name): an on switch shows a green track, not the label tint (white on white in Dark Mode); green pixels \(green)")
        }
    }

    @MainActor
    func testOpenAsTabShowsScreenSharingInTheWorkspace() throws {
        let app = openSheet()
        let open = app.buttons["screenSharing.openAsTab"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Open as Tab\n\(app.debugDescription)")
        attach(app.screenshot(), "01-sheet-with-open-as-tab")
        open.tap()

        XCTAssertTrue(app.buttons["screenSharing.done"].firstMatch.waitForNonExistence(timeout: 10), "the sheet closes")
        // The workspace screen's identifier covers its pages' own, so the tab shows by its
        // address pill and the page by the viewer's Touch picker.
        let pill = app.buttons["Screen Sharing, Your Macs"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "the Screen Sharing tab's address\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Touch"].firstMatch.waitForExistence(timeout: 10), "the tab's page: the viewer's choices\n\(app.debugDescription)")
        settle(1)
        attach(app.screenshot(), "02-screen-sharing-tab")

        tabsButton(app).tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Screen Sharing'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the tab grid lists Screen Sharing\n\(app.debugDescription)")
        settle(1)
        attach(app.screenshot(), "03-tab-grid-with-screen-sharing")
    }

    // MARK: Helpers

    @MainActor
    private func openSheet(appearance: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // Settings › Appearance for this launch (the app overrides the window's style from it).
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.appearance", appearance]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()
        tabsButton(app).tap()
        settle(1)
        let plus = app.buttons["New"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "+ menu\n\(app.debugDescription)")
        plus.tap()
        let entry = app.buttons["Screen Sharing"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Screen Sharing in +\n\(app.debugDescription)")
        entry.tap()
        let page = app.descendants(matching: .any)["screenSharing.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "Screen Sharing sheet\n\(app.debugDescription)")
        settle(1.5)
        return app
    }

    @MainActor
    private func tabsButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        return button
    }

    /// Pixels of the system green family (strong green over red and blue) in the trailing
    /// 80 points of `frame`, where a row's switch sits.
    static func greenPixels(in image: UIImage, trailingOf frame: CGRect) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let scale = CGFloat(cg.width) / image.size.width
        let region = CGRect(x: max(frame.minX, frame.maxX - 80), y: frame.minY, width: min(80, frame.width), height: frame.height)
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        guard let crop = cg.cropping(to: pixels) else { return 0 }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if g > 140, g - r > 60, g - b > 40 { count += 1 }
        }
        return count
    }

    /// Lets an animation finish before a screenshot (a run loop wait, not app synchronization).
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
