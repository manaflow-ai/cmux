import XCTest

/// The terminal's connection chip in each state, drawn by the production
/// `ConnectionChip` over a terminal page (`-cmux-mobile-recovery-gallery chip`).
/// Run with the fleet step's `video` argument for a capture of the four states
/// and of a Retry tap: each chip is one short word plus a spinner or symbol, the
/// sentence is its VoiceOver label, and a tap leaves the chip where it was.
final class ConnectionChipUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [expectation(description: "the capture shows the state")], timeout: seconds)
    }

    @MainActor
    func testEachStateIsAShortChipThatATapDoesNotMove() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "chip"]
        app.launch()
        defer { app.terminate() }
        let gallery = app.descendants(matching: .any)["recoveryGallery.chip"]
        guard gallery.waitForExistence(timeout: 30) else {
            throw XCTSkip("this build's gallery has no connection chip scene")
        }
        let sentences = [
            "Connecting to Mac Studio…",
            "Reconnecting to Mac Studio…",
            "Mac Studio is offline",
            "Can't reach this terminal",
        ]
        for sentence in sentences {
            let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", sentence)).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 10), "no chip reads \"\(sentence)\"")
            if !chip.isHittable { app.swipeUp() }
            // A chip, not a line: 26 pt tall and well short of the page's width.
            XCTAssertLessThanOrEqual(chip.frame.height, 34, "\"\(sentence)\" is taller than a chip")
            XCTAssertLessThan(chip.frame.width, app.frame.width * 0.6, "\"\(sentence)\" spans the page like a sentence line")
            hold(0.8)
        }
        // The chip is one accessibility element (its sentence), so it is found by label, not as a button.
        let offline = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mac Studio is offline")).firstMatch
        if !offline.isHittable { app.swipeDown() }
        XCTAssertTrue(offline.isHittable, "the offline chip cannot be tapped")
        let before = offline.frame
        for _ in 0..<3 {
            offline.tap()
            hold(0.6)
            XCTAssertEqual(offline.frame, before, "the chip moved or resized on its Retry tap")
        }
    }
}
