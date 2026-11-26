import UIKit
import XCTest

/// Two Feed glitches from the 2026-11-18 iPhone report, read off the real screen with
/// real touches on mock data:
///
/// - Dragging an open row's swipe actions back to the right closes the row in place. Before,
///   the team drawer's pan also closed it with an animated `setEditing(false)` while UIKit's
///   own swipe recognizer was dragging it closed, and for most of a second the row was drawn a
///   row's height too high, over the row above.
/// - Quote bubbles stay dark after the app leaves the screen and comes back (the switcher's
///   snapshots flip the app to light and back), and after a light-and-back appearance change.
///   Before, they came back solid white with their text unreadable until the row was rebuilt.
final class FeedRowGlitchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Swipe back

    @MainActor
    func testDraggingASwipeBackLeavesTheRowAboveAlone() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // A fixed Feed with no live traffic: only the drag moves anything.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        _ = feedChipsAfterSetup(app)
        app.buttons["Finished"].firstMatch.tap()
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let barBottom = app.navigationBars["Feed"].frame.maxY
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : list.frame.maxY

        // A row with at least 120 pt of the row above it on screen, and all of itself.
        func pick() -> (id: String, frame: CGRect)? {
            guard let snap = try? list.snapshot() else { return nil }
            return snap.children.lazy
                .filter { $0.identifier.hasPrefix("feed.row.") }
                .first { $0.frame.minY > barBottom + 140 && $0.frame.minY + 120 < tabBarTop - 20 }
                .map { ($0.identifier, $0.frame) }
        }
        var found = pick()
        for _ in 0..<6 where found == nil {
            list.swipeUp(velocity: .slow)
            found = pick()
        }
        let target = try XCTUnwrap(found, "a row with the row above it on screen\n\(app.debugDescription)")
        let row = list.cells[target.id]
        // The row above's part of the screen, which nothing here should change.
        let above = CGRect(x: 0, y: max(barBottom + 4, target.frame.minY - 120), width: list.frame.width,
                           height: target.frame.minY - 4 - max(barBottom + 4, target.frame.minY - 120))
        let reference = XCUIScreen.main.screenshot().image
        attach(reference, "before")

        row.swipeLeft()
        let done = list.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the row's swipe actions\n\(app.debugDescription)")
        attach(XCUIScreen.main.screenshot().image, "open")

        // Back to the right, a finger's drag from the row's leading part (the report's gesture).
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                    withVelocity: .default, thenHoldForDuration: 0)
        // The jump lasted most of a second: look at the screen as often as it can be read for 1.5 s.
        var worst: (changed: Double, image: UIImage)?
        let until = Date().addingTimeInterval(1.5)
        while Date() < until {
            let image = XCUIScreen.main.screenshot().image
            let changed = Self.changedFraction(image, reference, in: above)
            if changed > (worst?.changed ?? -1) { worst = (changed, image) }
        }
        if let worst { attach(worst.image, String(format: "worst-%.3f", worst.changed)) }
        XCTAssertTrue(waitGone(done), "the swipe actions close")
        let changed = worst?.changed ?? 0
        XCTAssertLessThan(changed, 0.05, "the row above changed under the closing row (\(Int(changed * 100))% of its pixels)")
        // And the row ends where it started.
        XCTAssertEqual(row.frame.minY, target.frame.minY, accuracy: 1, "the row is back in its place")
    }

    // MARK: Bubbles after the app comes back

    @MainActor
    func testQuoteBubblesStayDarkWhenTheAppComesBack() throws {
        XCUIDevice.shared.appearance = .dark
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The app's own Dark setting as well: the fleet's UI simulator boots light, and the device
        // appearance call does not reach it there.
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore", "-cmuxMobile.settings.appearance", "dark"]
        app.launch()
        _ = feedChipsAfterSetup(app)
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let quote = list.buttons.matching(NSPredicate(format: "label BEGINSWITH 'In reply to your message'")).firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 10), "a quote of your message\n\(app.debugDescription)")

        func brightness(_ name: String) -> Double {
            XCTAssertTrue(quote.waitForExistence(timeout: 10), "the quote after \(name)")
            // On screen, so its pixels are the bubble's (an off-screen quote would read as dark).
            XCTAssertTrue(quote.isHittable && app.windows.firstMatch.frame.contains(quote.frame),
                          "the quote is on screen after \(name): \(quote.frame)")
            let image = XCUIScreen.main.screenshot().image
            attach(image, name)
            return Self.brightFraction(image, in: quote.frame)
        }
        let start = brightness("dark")
        XCTAssertLessThan(start, 0.2, "the bubble starts dark")

        // Leave the app and come back, as from another app.
        XCUIDevice.shared.press(.home)
        pause(3)
        app.activate()
        pause(1.5)
        let back = brightness("back-from-home")
        XCTAssertLessThan(back, 0.2, "the bubble is dark again after the app comes back (\(Int(back * 100))% bright)")
        // The light-and-back flip itself is FeedRowVisualTests' (a real cell in a window whose
        // appearance changes); the device appearance call does not reach the fleet's simulator.
    }

    // MARK: Helpers

    @MainActor private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    @MainActor private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor private func attach(_ image: UIImage, _ name: String) {
        let shot = XCTAttachment(image: image)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// RGBA8 pixels of `image` at its pixel size.
    static func pixels(_ image: UIImage) -> (data: [UInt8], width: Int, height: Int, scale: CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data, w, h, CGFloat(w) / max(image.size.width, 1))
    }

    /// The share of pixels in `rect` (points) that differ clearly between two screenshots.
    static func changedFraction(_ a: UIImage, _ b: UIImage, in rect: CGRect) -> Double {
        guard let pa = pixels(a), let pb = pixels(b), pa.width == pb.width, pa.height == pb.height else { return 1 }
        let s = pa.scale
        let x0 = max(0, Int(rect.minX * s)), x1 = min(pa.width, Int(rect.maxX * s))
        let y0 = max(0, Int(rect.minY * s)), y1 = min(pa.height, Int(rect.maxY * s))
        var changed = 0, total = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let i = (y * pa.width + x) * 4
                let d = max(abs(Int(pa.data[i]) - Int(pb.data[i])), abs(Int(pa.data[i + 1]) - Int(pb.data[i + 1])),
                            abs(Int(pa.data[i + 2]) - Int(pb.data[i + 2])))
                if d > 48 { changed += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }

    /// The share of near-white pixels in `rect` (points): a light bubble on the dark Feed.
    static func brightFraction(_ image: UIImage, in rect: CGRect) -> Double {
        guard let p = pixels(image) else { return 1 }
        let s = p.scale
        let x0 = max(0, Int(rect.minX * s)), x1 = min(p.width, Int(rect.maxX * s))
        let y0 = max(0, Int(rect.minY * s)), y1 = min(p.height, Int(rect.maxY * s))
        var bright = 0, total = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let i = (y * p.width + x) * 4
                if p.data[i] > 200, p.data[i + 1] > 200, p.data[i + 2] > 200 { bright += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(bright) / Double(total)
    }
}
