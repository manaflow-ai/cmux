import XCTest

final class TerminalSmallWindowScrollUITests: XCTestCase {
    private let targetWindowSize = CGSize(width: 800, height: 220)

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSmallWindowCanScrollToTop() {
        let app = makeApp()
        app.launch()
        app.activate()

        let offset = app.descendants(matching: .any)["TerminalScrollOffset"].firstMatch
        _ = offset.waitForExistence(timeout: 1.0)

        let window = app.windows.firstMatch
        guard let target = resolveScrollTarget(app: app) else { return }
        waitForSmallViewport(window: window, target: target)
        runScrollChecks(on: target, app: app, offsetElement: offset)
    }

    private func runScrollChecks(on target: XCUIElement, app: XCUIApplication, offsetElement: XCUIElement) {
        target.click()
        let lineCount = 200
        app.typeText("seq 1 \(lineCount)\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTContext.runActivity(named: "Terminal scroll offset raw") { activity in
            let attachment = XCTAttachment(string: "metrics=\(metricsString(app: app))")
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        let metrics = waitForScrollbarMetrics(app: app, offsetElement: offsetElement)
        XCTAssertGreaterThan(metrics.total, 0)
        XCTAssertGreaterThan(metrics.len, 0)
        XCTAssertGreaterThan(metrics.total, metrics.len)
        let expectedBottomOffset = Double(metrics.total - metrics.len)

        var minObservedOffset = Double(metrics.offset)
        var maxObservedOffset = Double(metrics.offset)
        for _ in 0..<8 {
            target.scroll(byDeltaX: 0, deltaY: 1200)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let offset = extractOffset(app: app, offsetElement: offsetElement)
            minObservedOffset = min(minObservedOffset, offset)
            maxObservedOffset = max(maxObservedOffset, offset)
        }

        for _ in 0..<8 {
            target.scroll(byDeltaX: 0, deltaY: -1200)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let offset = extractOffset(app: app, offsetElement: offsetElement)
            minObservedOffset = min(minObservedOffset, offset)
            maxObservedOffset = max(maxObservedOffset, offset)
        }

        XCTContext.runActivity(named: "Terminal scroll range") { activity in
            let attachment = XCTAttachment(
                string: String(
                    format: "minOffset=%.1f maxOffset=%.1f expectedBottomOffset=%.1f total=%@ len=%@",
                    minObservedOffset,
                    maxObservedOffset,
                    expectedBottomOffset,
                    String(metrics.total),
                    String(metrics.len)
                )
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertLessThanOrEqual(minObservedOffset, 1.0)
        XCTAssertGreaterThanOrEqual(maxObservedOffset, expectedBottomOffset - 1.0)
    }

    private func waitForSmallViewport(window: XCUIElement, target: XCUIElement) {
        let deadline = Date().addingTimeInterval(5.0)
        var frame = window.exists ? window.frame : target.frame
        while Date() < deadline,
              frame.height >= targetWindowSize.height + 120 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            frame = window.exists ? window.frame : target.frame
        }
        XCTAssertLessThan(frame.height, targetWindowSize.height + 120)
    }

    private func waitForScrollbarMetrics(
        app: XCUIApplication,
        offsetElement: XCUIElement
    ) -> (offset: UInt64, len: UInt64, total: UInt64) {
        let deadline = Date().addingTimeInterval(6.0)
        var offset = extractOffsetValue(app: app, offsetElement: offsetElement)
        var len = extractLenValue(app: app, offsetElement: offsetElement)
        var total = extractTotalValue(app: app, offsetElement: offsetElement)
        while (total == 0 || len == 0), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            offset = extractOffsetValue(app: app, offsetElement: offsetElement)
            len = extractLenValue(app: app, offsetElement: offsetElement)
            total = extractTotalValue(app: app, offsetElement: offsetElement)
        }
        return (offset, len, total)
    }

    private func extractOffset(app: XCUIApplication, offsetElement: XCUIElement) -> Double {
        Double(extractOffsetValue(app: app, offsetElement: offsetElement))
    }

    private func extractOffsetValue(app: XCUIApplication, offsetElement: XCUIElement) -> UInt64 {
        guard let value = metricsString(app: app, offsetElement: offsetElement) else { return 0 }
        return extractUInt64(prefix: "offset=", from: value) ?? 0
    }

    private func extractLenValue(app: XCUIApplication, offsetElement: XCUIElement) -> UInt64 {
        guard let value = metricsString(app: app, offsetElement: offsetElement) else { return 0 }
        return extractUInt64(prefix: "len=", from: value) ?? 0
    }

    private func extractTotalValue(app: XCUIApplication, offsetElement: XCUIElement) -> UInt64 {
        guard let value = metricsString(app: app, offsetElement: offsetElement) else { return 0 }
        return extractUInt64(prefix: "total=", from: value) ?? 0
    }

    private func metricsString(app: XCUIApplication, offsetElement: XCUIElement? = nil) -> String? {
        let candidates: [XCUIElement] = [
            offsetElement ?? app.descendants(matching: .any)["TerminalScrollOffset"].firstMatch,
            app.descendants(matching: .any)["TerminalScrollView"].firstMatch,
            app.descendants(matching: .any)["TerminalSurfaceView"].firstMatch,
        ]
        for element in candidates {
            if let value = element.value as? String, value.contains("offset=") {
                return value
            }
            let label = element.label
            if label.contains("offset=") || label.contains("x=") {
                return label
            }
            if let value = element.value as? String, !value.isEmpty {
                return value
            }
            if !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private func extractUInt64(prefix: String, from value: String) -> UInt64? {
        for part in value.split(separator: " ") where part.hasPrefix(prefix) {
            return UInt64(part.dropFirst(prefix.count))
        }
        return nil
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CMUXD_DISABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_SIZE"] =
            "\(Int(targetWindowSize.width))x\(Int(targetWindowSize.height))"
        return app
    }

    private func resolveScrollTarget(app: XCUIApplication) -> XCUIElement? {
        _ = app.wait(for: .runningForeground, timeout: 10.0)
        let window = app.windows.firstMatch
        let terminal = app.descendants(matching: .any)["TerminalSurfaceView"].firstMatch
        if terminal.waitForExistence(timeout: 12.0) {
            return terminal
        }
        let fallback = app.descendants(matching: .any)["TerminalScrollView"].firstMatch
        if fallback.waitForExistence(timeout: 8.0) {
            return fallback
        }
        if window.exists {
            return window
        }
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        app.typeKey("n", modifierFlags: .command)
        if terminal.waitForExistence(timeout: 10.0) {
            return terminal
        }
        if fallback.waitForExistence(timeout: 10.0) {
            return fallback
        }
        if window.exists {
            return window
        }
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Terminal view not found")
        return nil
    }
}
