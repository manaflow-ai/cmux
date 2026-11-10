import XCTest

/// iOS reliability matrix, axis `device`, on the real app (cmux-next-ios/reliability-matrix/cells.json,
/// the `ios-ui` cells): the largest Dynamic Type size from launch, dark appearance and a
/// device rotation, against mock data. The kit's DeviceAxesTests check the same shapes
/// on the list and composer in a window; these launch the whole app the way a person's
/// settings do. GitHub CI builds the kit, not the app, so these run on the fleet's simulator
/// route: `scripts/ci/cmux-next-ios-sim.sh test ui=DeviceAxesUITests`.
final class DeviceAxesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"] + arguments
        app.launch()
        // First run of mock data: pick the team whose Macs hold the workspaces.
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A row lies inside the app's window, sideways too.
    @MainActor
    private func assertInsideWindow(_ element: XCUIElement, _ app: XCUIApplication, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, "\(what) starts left of the window: \(frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(what) runs past the window: \(frame) in \(window)", file: file, line: line)
    }

    /// Launched at AX5 (`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`):
    /// the list's rows fit the window's width and a workspace opens from a tap.
    @MainActor
    func testDynamicTypeAX5Launch() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row at AX5\n\(app.debugDescription)")
        XCTAssertTrue(row.isHittable, "the row at AX5 is not hittable")
        assertInsideWindow(row, app, "the AX5 row")
        attach(app, "ax5-list")
        row.tap()
        XCTAssertTrue(app.collectionViews["workspaces.list"].waitForNonExistence(timeout: 10) || !row.isHittable,
                      "the tap did not open the workspace at AX5")
        attach(app, "ax5-workspace")
    }

    /// Launched with the app's appearance set to Dark (Settings > Appearance, read from
    /// `cmuxMobile.settings.appearance`): the screen is dark.
    @MainActor
    func testDarkAppearance() throws {
        let app = launch(["-cmuxMobile.settings.appearance", "dark"])
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row in dark\n\(app.debugDescription)")
        attach(app, "dark-list")
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let luminance = Self.meanLuminance(image)
        XCTAssertLessThan(luminance, 0.35, "the dark screen's mean luminance is \(luminance)")
    }

    /// Rotated to landscape and back with a workspace open: the workspace stays open and
    /// the list keeps its rows. (The app turns only in Screen Sharing; elsewhere its window
    /// stays portrait, and a rotation must not reset what is on screen.)
    @MainActor
    func testRotationKeepsTheOpenWorkspace() {
        let app = launch()
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row is gone in landscape")
        assertInsideWindow(row, app, "the landscape row")
        attach(app, "rotation-list-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row is gone back in portrait")

        row.tap()
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.waitForNonExistence(timeout: 10) || !row.isHittable, "the tap did not open the workspace")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        XCTAssertFalse(row.isHittable, "a rotation closed the open workspace")
        attach(app, "rotation-workspace")
    }

    private static func meanLuminance(_ image: CGImage) -> Double {
        let width = 32, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 1 }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(width * height) / 255
    }
}
