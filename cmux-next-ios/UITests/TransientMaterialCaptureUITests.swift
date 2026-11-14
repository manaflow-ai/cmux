import XCTest

/// Fleet screenshots of production transient surfaces. Missing presentation
/// fails this capture; a launch alone is never accepted as visual evidence.
final class TransientMaterialCaptureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testLightMaterials() { capture(look: "light", appearance: .light) }
    @MainActor func testDarkMaterials() { capture(look: "dark", appearance: .dark) }

    @MainActor private func capture(look: String, appearance: XCUIDevice.Appearance) {
        XCUIDevice.shared.appearance = appearance
        XCUIDevice.shared.orientation = .portrait
        for surface in ["toast", "banner", "sheet", "palette", "menu"] {
            for variant in ["before", "quieter", "standard", "denser"] {
                let app = XCUIApplication()
                app.launchArguments = ["-cmux-mobile-recovery-gallery", "transient-\(surface)",
                                       "-cmux-mobile-gallery-appearance", look,
                                       "-cmux-mobile-material-variant", variant]
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launch()
                XCTAssertTrue(app.staticTexts["transient.variant"].waitForExistence(timeout: 20),
                              "\(surface) / \(variant) / \(look)\n\(app.debugDescription)")
                switch surface {
                case "sheet":
                    app.buttons["transient.openSheet"].tap()
                    XCTAssertTrue(app.navigationBars["Team appearance"].waitForExistence(timeout: 10),
                                  "Team Appearance presentation\n\(app.debugDescription)")
                case "palette":
                    app.buttons["transient.openPalette"].tap()
                    XCTAssertTrue(app.navigationBars["Command Palette"].waitForExistence(timeout: 10),
                                  "Command palette presentation\n\(app.debugDescription)")
                case "menu":
                    app.buttons["transient.openMenu"].tap()
                    XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 10),
                                  "Native menu presentation\n\(app.debugDescription)")
                default: break
                }
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "transient-\(surface)-\(variant)-\(look)"
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }
}
