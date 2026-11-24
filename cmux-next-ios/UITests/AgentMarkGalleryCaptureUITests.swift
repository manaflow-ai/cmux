import XCTest

/// A terminal agent's avatar against a GUI agent chat's (Leo, 2026-11-24: "terminal agent chats. can
/// they be demarcated a bit differently/should they? than gui agent chats"), drawn by the gallery
/// (`-cmux-mobile-recovery-gallery agentmark`): every variant side by side, then each as Feed rows,
/// in light and dark.
final class AgentMarkGalleryCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentMarkGallery() throws {
        for appearance in ["light", "dark"] {
            XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
            for scene in ["agentmark", "agentmark-a", "agentmark-b", "agentmark-c", "agentmark-d"] {
                let app = XCUIApplication()
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launchArguments += ["-cmux-mobile-recovery-gallery", scene, "-cmux-mobile-no-restore",
                                        "-cmux-mobile-gallery-appearance", appearance]
                app.launch()
                let root = app.descendants(matching: .any)["recoveryGallery.agentmark"]
                XCTAssertTrue(root.waitForExistence(timeout: 30), "\(scene)\n\(app.debugDescription)")
                Thread.sleep(forTimeInterval: 0.5)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(scene)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
