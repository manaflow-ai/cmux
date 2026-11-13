import XCTest

/// The shared Retry's tap on Home's "Couldn't load" note, drawn by the production
/// views (`-cmux-mobile-recovery-gallery home`). Run with the fleet step's `video`
/// argument at the base and at the head for a before and after of the tap: the
/// capsule keeps its size and colors and its spinner turns in place of the title.
final class RetryAnimationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Lets the recording show the load play out (nothing on screen to wait for: the spinner is not an element).
    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [expectation(description: "the load plays out")], timeout: seconds)
    }

    @MainActor
    func testHomeRetryTapKeepsTheCapsuleSteady() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "home"]
        app.launch()
        defer { app.terminate() }
        let instant = app.buttons["recoveryGallery.home.retry.instant"]
        let slow = app.buttons["recoveryGallery.home.retry.slow"]
        guard instant.waitForExistence(timeout: 30) else {
            throw XCTSkip("this build's gallery has no Home recovery scene")
        }
        let before = (instant.frame, slow.frame)
        for _ in 0..<3 {
            instant.tap()
            XCTAssertEqual(instant.frame.size, before.0.size, "the instant Retry resized on its tap")
            hold(1.2)
            slow.tap()
            XCTAssertEqual(slow.frame.size, before.1.size, "the slow Retry resized while loading")
            hold(2)
        }
        XCTAssertEqual(slow.frame, before.1, "the slow Retry moved")
    }
}
