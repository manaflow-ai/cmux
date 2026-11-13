import XCTest

/// Cloud workspaces in the Workspaces list and on the Cloud Machines page, drawn by the
/// production views over the gallery's fixed store (`-cmux-mobile-recovery-gallery
/// cloudworkspaces` and `cloudmachineworkspaces`, `CloudWorkspacesGallery`): every Cloud
/// machine state's line, a paused machine's folded workspace, Start, the + menu's New
/// Workspace on… with the Cloud machines, New Cloud Workspace's pending line, and a machine
/// page's Workspaces section. Light and dark.
final class CloudWorkspacesCaptureUITests: XCTestCase {
    static let running = "vm_gallery0000000000001"
    static let paused = "vm_gallery0000000000002"
    static let waking = "vm_gallery0000000000003"
    static let failed = "vm_gallery0000000000004"
    static let empty = "vm_gallery0000000000005"
    static let pending = "vm_gallery0000000000006"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ scene: String, _ name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", scene, "-cmux-mobile-no-restore",
                                "-cmux-mobile-gallery-appearance", name]
        app.launch()
        return app
    }

    @MainActor func testCloudWorkspacesListLight() throws { try walkList(.light, "light") }
    @MainActor func testCloudWorkspacesListDark() throws { try walkList(.dark, "dark") }
    @MainActor func testCloudMachineWorkspacesLight() throws { try walkMachines(.light, "light") }
    @MainActor func testCloudMachineWorkspacesDark() throws { try walkMachines(.dark, "dark") }

    @MainActor
    private func walkList(_ appearance: XCUIDevice.Appearance, _ name: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = launch("cloudworkspaces", name)
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["workspaces.cloud.\(Self.paused)"].waitForExistence(timeout: 30),
                      "paused line\n\(app.debugDescription)")
        // Cloud rows name their machine ("main · Build box · Cloud") among the Mac's.
        XCTAssertTrue(app.buttons["workspace.row.ws-cloud-1"].exists, "a Cloud workspace row")
        XCTAssertTrue(app.buttons["workspace.row.ws-mac-1"].exists, "the Mac's row")
        XCTAssertTrue(app.buttons["workspaces.cloud.start.\(Self.paused)"].exists, "Start on the paused machine")
        shot(app, "\(name)-01-list")

        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["Repro sandbox · Cloud · Waking up…"].firstMatch.waitForExistence(timeout: 5), "waking\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["workspaces.cloud.retry.\(Self.failed)"].exists, "Retry on the failed machine")
        XCTAssertTrue(app.buttons["workspaces.cloud.new.\(Self.empty)"].exists, "New Workspace on the empty machine")
        XCTAssertTrue(app.descendants(matching: .any)["Starting Cloud Machine…"].firstMatch.exists, "the pending New Cloud Workspace line")
        shot(app, "\(name)-02-list-states")

        app.swipeDown()
        // The paused machine's folded workspace unfolds in place.
        app.descendants(matching: .any)["workspaces.cloud.\(Self.paused)"].firstMatch.tap()
        XCTAssertTrue(app.buttons["workspace.row.ws-paused-1"].waitForExistence(timeout: 5), "unfolded\n\(app.debugDescription)")
        shot(app, "\(name)-03-paused-unfolded")

        app.buttons["workspaces.cloud.start.\(Self.paused)"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Nightly evals · Cloud · Waking up…"].firstMatch.waitForExistence(timeout: 5), "started\n\(app.debugDescription)")
        shot(app, "\(name)-04-started")

        // The + button's long-press menu: New Workspace on… lists the Cloud machines with the Mac.
        app.buttons["workspaces.new"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["workspaces.newCloud"].waitForExistence(timeout: 5), "menu\n\(app.debugDescription)")
        shot(app, "\(name)-05-new-menu")
        app.buttons["workspaces.newOn"].tap()
        XCTAssertTrue(app.buttons["workspaces.newOn.\(Self.running)"].waitForExistence(timeout: 5), "picker\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["workspaces.newOn.mac_gallery_studio"].exists)
        shot(app, "\(name)-06-new-on-picker")
        app.buttons["workspaces.newOn.\(Self.running)"].tap()

        // Back on the list, New Cloud Workspace shows its pending line at once.
        if app.buttons["workspaces.new"].waitForExistence(timeout: 5) {
            app.buttons["workspaces.new"].press(forDuration: 1.0)
            XCTAssertTrue(app.buttons["workspaces.newCloud"].waitForExistence(timeout: 5))
            app.buttons["workspaces.newCloud"].tap()
            app.swipeUp()
            XCTAssertTrue(app.descendants(matching: .any)["Starting Cloud Machine 2…"].firstMatch.waitForExistence(timeout: 5), "pending\n\(app.debugDescription)")
            shot(app, "\(name)-07-new-cloud-pending")
        }
    }

    @MainActor
    private func walkMachines(_ appearance: XCUIDevice.Appearance, _ name: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = launch("cloudmachineworkspaces", name)
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars["Cloud Machines"].waitForExistence(timeout: 30), "page\n\(app.debugDescription)")
        app.staticTexts["Build box"].tap()
        XCTAssertTrue(app.navigationBars["Build box"].waitForExistence(timeout: 10), "detail\n\(app.debugDescription)")
        app.swipeUp()
        XCTAssertTrue(app.buttons["cloudMachines.workspaces.new"].waitForExistence(timeout: 5), "workspaces\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["cloudMachines.workspace.ws-cloud-1"].exists)
        shot(app, "\(name)-01-machine-workspaces")

        // An existing row opens its workspace (a route on the stack, the path every open takes).
        app.buttons["cloudMachines.workspace.ws-cloud-1"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.ws-cloud-1"].waitForExistence(timeout: 10), "workspace\n\(app.debugDescription)")
        shot(app, "\(name)-02-workspace")
        // Back to the machine's page, and New Workspace opens its new workspace the same way.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Build box"].waitForExistence(timeout: 10), "back\n\(app.debugDescription)")
        app.terminate()

        let again = launch("cloudmachineworkspaces", name)
        XCTAssertTrue(again.navigationBars["Cloud Machines"].waitForExistence(timeout: 30))
        again.staticTexts["Nightly evals"].tap()
        XCTAssertTrue(again.navigationBars["Nightly evals"].waitForExistence(timeout: 10))
        again.swipeUp()
        XCTAssertTrue(again.staticTexts["cloudMachines.workspaces.stopped"].waitForExistence(timeout: 5), "stopped\n\(again.debugDescription)")
        shot(again, "\(name)-03-paused-machine")
        again.navigationBars["Nightly evals"].buttons.firstMatch.tap()
        XCTAssertTrue(again.staticTexts["Repro sandbox"].waitForExistence(timeout: 10))
        again.staticTexts["Repro sandbox"].tap()
        XCTAssertTrue(again.navigationBars["Repro sandbox"].waitForExistence(timeout: 10))
        again.swipeUp()
        shot(again, "\(name)-04-starting-machine")
        again.terminate()
    }
}
