import XCTest

/// Safari's still tab frame (person, 2026-11-18: "freeze the shown frame like Safari does
/// (e.g. a FotMob video) so the expand animation isn't jarring"). A streamed browser tab
/// playing a clip (`-cmux-mobile-browser-events video`, the real tab source, model and
/// decoder over a synthetic H.264 stream) holds one frame from the moment it shrinks into
/// the tab grid, while it rests there as its card, and while it grows back; it plays again
/// once the page settles. Before the fix the card kept playing on the grid.
final class BrowserTabFreezeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheGridCardHoldsOneFrameAndThePagePlaysAgain() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-cmux-mobile-browser-events", "video"]
        app.launch()

        let stream = app.descendants(matching: .any)["browser.stream"]
        XCTAssertTrue(stream.waitForExistence(timeout: 20), "browser page\n\(app.debugDescription)")
        // The clip plays on the page.
        XCTAssertTrue(waitForChange(app, timeout: 15), "the clip never started playing on the page")
        attach(app, "1-page-playing")

        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "tabs button\n\(app.debugDescription)")
        tabs.tap()
        // The zoom out, frame by frame.
        burst(app, "2-zoom-out", count: 6)
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "grid Done\n\(app.debugDescription)")
        settle(app)
        attach(app, "3-grid-card")

        // On the grid the card is one still frame: two captures a second apart match.
        let first = app.screenshot()
        pause(1.2) // the clip runs at 30 fps: 36 frames apart
        let second = app.screenshot()
        let moved = Self.differs(first, second)
        XCTAssertFalse(moved, "the grid card kept playing: the tab did not hold its frame")
        attach(app, "4-grid-card-1s-later")

        done.tap()
        // The zoom back in, frame by frame: the held frame grows.
        burst(app, "5-zoom-in", count: 6)
        settle(app)
        // Settled on the page: the clip plays again.
        XCTAssertTrue(waitForChange(app, timeout: 10), "the page stayed frozen after it settled")
        attach(app, "6-page-playing-again")
    }

    /// Waits until two captures 0.3 s apart differ (the clip is playing).
    @MainActor
    private func waitForChange(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let a = app.screenshot()
            pause(0.3)
            if Self.differs(a, app.screenshot()) { return true }
        }
        return false
    }

    /// Lets the zoom spring come to rest.
    @MainActor
    private func settle(_ app: XCUIApplication) {
        pause(1.0) // the zoom spring rests in under 1 s
    }

    /// UI-test pacing between captures (XCTWaiter, no thread sleep).
    @MainActor
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pace")], timeout: seconds)
    }

    @MainActor
    private func burst(_ app: XCUIApplication, _ name: String, count: Int) {
        for index in 0..<count { attach(app, "\(name)-\(index)") }
    }

    /// Whether two captures differ below the status bar (its clock may tick).
    @MainActor
    static func differs(_ a: XCUIScreenshot, _ b: XCUIScreenshot) -> Bool {
        guard let ca = a.image.cgImage, let cb = b.image.cgImage, ca.width == cb.width, ca.height == cb.height else { return true }
        let top = ca.height / 12
        let rect = CGRect(x: 0, y: top, width: ca.width, height: ca.height - top)
        guard let pa = ca.cropping(to: rect), let pb = cb.cropping(to: rect) else { return true }
        return bytes(pa) != bytes(pb)
    }

    static func bytes(_ image: CGImage) -> Data {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
