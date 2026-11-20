import XCTest

/// Stress finding F8 (scratch diagnostic, never lands): after the list rig opens a 200-turn chat and
/// jumps to its top (`CMUX_MOBILE_LIST_LEAVE_NEWEST` unset, as a reader leaves the newest turn), are
/// rows near the reader blank only while older pages are read in, or do they stay blank?
/// Screenshots and the count of on-screen transcript texts at 3, 8, 20 and 45 s after launch answer it.
final class ChatJumpTopSettleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testRowsAfterJumpToTopSettle() {
        var counts: [String] = []
        for turns in [40, 200] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
            app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = String(turns)
            app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
            let launched = Date()
            app.launch()

            for mark in [3.0, 8.0, 20.0, 45.0] {
                let left = mark - Date().timeIntervalSince(launched)
                if left > 0 { _ = XCTWaiter().wait(for: [XCTestExpectation(description: "t\(Int(mark))")], timeout: left) }
                let frame = app.windows.firstMatch.frame
                // Texts drawn inside the window's middle band (below the navigation bar, above the composer).
                let band = frame.insetBy(dx: 0, dy: frame.height * 0.18)
                // One snapshot of the tree: rows come and go while pages are read in, so live
                // element queries can name a row that is gone by the time it is read.
                var visible = -1
                var top: (y: CGFloat, label: String)?
                if let root = try? app.snapshot() {
                    var stack: [any XCUIElementSnapshot] = [root]
                    visible = 0
                    while let node = stack.popLast() {
                        if node.elementType == .staticText, !node.frame.isEmpty, band.intersects(node.frame), !node.label.isEmpty {
                            visible += 1
                            if top == nil || node.frame.minY < top!.y { top = (node.frame.minY, node.label) }
                        }
                        stack.append(contentsOf: node.children)
                    }
                }
                counts.append("n\(turns)-t\(Int(mark))s=\(visible)[\(String((top?.label ?? "-").prefix(24)))]")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "f8-n\(turns)-t\(Int(mark))s"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.terminate()
        }
        let summary = XCTAttachment(string: counts.joined(separator: " "))
        summary.name = "f8-visible-text-counts"
        summary.lifetime = .keepAlways
        add(summary)
        print("F8 visible transcript texts: \(counts.joined(separator: " "))")
        // The fleet step keeps only failure lines when it drops the evidence zip (empty ui_cold under
        // set -u, #47685), so the counts travel as a failure message.
        XCTFail("F8-COUNTS \(counts.joined(separator: " "))")
    }
}
