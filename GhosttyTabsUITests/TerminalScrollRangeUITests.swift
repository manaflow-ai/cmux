import XCTest

final class TerminalScrollRangeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testScrollToTopAfterResizes() {
        let app = makeApp()
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_SIZES"] =
            "900x600;1100x700;960x640;1200x720;880x610;1000x680;920x620;1150x700;900x600"
        app.launch()
        app.activate()

        let offset = app.descendants(matching: .any)["TerminalScrollOffset"].firstMatch
        _ = offset.waitForExistence(timeout: 1.0)

        guard let target = resolveScrollTarget(app: app) else { return }
        target.click()

        app.typeText("seq 1 400\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let metrics = waitForScrollbarMetrics(app: app, offsetElement: offset)
        XCTAssertGreaterThan(metrics.total, metrics.len)

        RunLoop.current.run(until: Date().addingTimeInterval(1.8))

        for _ in 0..<10 {
            target.scroll(byDeltaX: 0, deltaY: -1600)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }

        var offsetValue = extractOffsetValue(app: app, offsetElement: offset)
        let downMetrics = readScrollMetricsFull(app: app, offsetElement: offset)
        for _ in 0..<20 {
            if offsetValue <= 1 { break }
            target.scroll(byDeltaX: 0, deltaY: 1600)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            offsetValue = extractOffsetValue(app: app, offsetElement: offset)
        }
        let upMetrics = readScrollMetricsFull(app: app, offsetElement: offset)

        XCTContext.runActivity(named: "Scroll to top offset") { activity in
            let expectedDownY = expectedScrollY(metrics: downMetrics)
            let expectedUpY = expectedScrollY(metrics: upMetrics)
            let attachment = XCTAttachment(
                string: """
                offset=\(offsetValue)
                down: y=\(downMetrics.y) expectedY=\(expectedDownY) offset=\(downMetrics.offset) len=\(downMetrics.len) total=\(downMetrics.total)
                up: y=\(upMetrics.y) expectedY=\(expectedUpY) offset=\(upMetrics.offset) len=\(upMetrics.len) total=\(upMetrics.total)
                """
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertLessThanOrEqual(offsetValue, 1)
        let tolerance = max(2.0, max(downMetrics.cellHeight, upMetrics.cellHeight))
        XCTAssertGreaterThan(downMetrics.offset, 0)
        XCTAssertLessThanOrEqual(abs(downMetrics.y - expectedScrollY(metrics: downMetrics)), tolerance)
        XCTAssertLessThanOrEqual(abs(upMetrics.y - expectedScrollY(metrics: upMetrics)), tolerance)
    }

    func testNoScrollbarWhenNoScrollback() {
        let app = makeApp()
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_SIZES"] = "1200x1600"
        app.launch()
        app.activate()

        let offset = app.descendants(matching: .any)["TerminalScrollOffset"].firstMatch
        _ = offset.waitForExistence(timeout: 1.0)

        guard let target = resolveScrollTarget(app: app) else { return }
        target.click()

        app.typeText("printf '\\033[3J\\033[H'\\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let metrics = waitForScrollbarMetrics(app: app, offsetElement: offset)
        let hasScroller = extractHasScroller(app: app, offsetElement: offset)

        XCTContext.runActivity(named: "Scrollbar visibility") { activity in
            let attachment = XCTAttachment(
                string: "total=\(metrics.total) len=\(metrics.len) hasScroller=\(hasScroller)"
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertGreaterThan(metrics.len, 0)
        XCTAssertLessThanOrEqual(metrics.total, metrics.len)
        XCTAssertEqual(hasScroller, 0)
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

    private func extractHasScroller(app: XCUIApplication, offsetElement: XCUIElement) -> Int {
        guard let value = metricsString(app: app, offsetElement: offsetElement) else { return -1 }
        return extractInt(prefix: "hasScroller=", from: value) ?? -1
    }

    private func readScrollMetricsFull(
        app: XCUIApplication,
        offsetElement: XCUIElement
    ) -> (y: Double, cellHeight: Double, offset: UInt64, len: UInt64, total: UInt64) {
        guard let value = metricsString(app: app, offsetElement: offsetElement) else {
            return (0, 0, 0, 0, 0)
        }
        let y = extractDouble(prefix: "y=", from: value) ?? 0
        let cellHeight = extractDouble(prefix: "cellHeight=", from: value) ?? 0
        let offset = extractUInt64(prefix: "offset=", from: value) ?? 0
        let len = extractUInt64(prefix: "len=", from: value) ?? 0
        let total = extractUInt64(prefix: "total=", from: value) ?? 0
        return (y, cellHeight, offset, len, total)
    }

    private func expectedScrollY(metrics: (y: Double, cellHeight: Double, offset: UInt64, len: UInt64, total: UInt64)) -> Double {
        guard metrics.cellHeight > 0 else { return 0 }
        let total = Double(metrics.total)
        let offset = Double(metrics.offset)
        let len = Double(metrics.len)
        let expected = (total - offset - len) * metrics.cellHeight
        return max(0, expected)
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

    private func extractInt(prefix: String, from value: String) -> Int? {
        for part in value.split(separator: " ") where part.hasPrefix(prefix) {
            return Int(part.dropFirst(prefix.count))
        }
        return nil
    }

    private func extractDouble(prefix: String, from value: String) -> Double? {
        for part in value.split(separator: " ") where part.hasPrefix(prefix) {
            return Double(part.dropFirst(prefix.count))
        }
        return nil
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CMUXD_DISABLE"] = "1"
        return app
    }
}
