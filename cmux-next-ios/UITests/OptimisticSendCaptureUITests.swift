import QuartzCore
import XCTest

/// A text send on a slow link, captured for before and after (Leo, 2026-11-24: "i think we can
/// maybe be more optimistic sometimes. it is a bit slow on ios."). Captures, not a gate.
///
/// - `testSlowLinkSend`: `CMUX_MOBILE_MOCK_LINK=slow` holds each send 600 ms on its way to the
///   mock Mac. Screenshots right after the tap, at 300 ms and after the echo; with the step's
///   `video` argument, the recording shows the whole send.
/// - `testDownLinkSend`: the Mac is out of reach (`down`), so the send never arrives.
/// - `testDuressThousandTurnSend`: a 1000-turn chat. With the send trace on, it keeps the app's
///   trace (`ev=send` at the tap, `ev=pending-bubble` when the pending bubble first draws, and
///   every frame's visible transcript rows) as `optimistic-trace-duress.txt`, for tap-to-bubble
///   and tap-to-row times.
final class OptimisticSendCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func testSlowLinkSend() throws {
        let app = try open(["CMUX_MOBILE_MOCK_LINK": "slow"], listed: true)
        send(app, "is this optimistic yet?")
        attach(app, "slow-0-right-after-tap")
        settle(0.3)
        attach(app, "slow-1-at-300ms")
        settle(3)
        attach(app, "slow-2-after-echo")
    }

    @MainActor func testDownLinkSend() throws {
        let app = try open(["CMUX_MOBILE_MOCK_LINK": "down"], listed: true)
        send(app, "sent while the Mac is away")
        attach(app, "down-0-right-after-tap")
        settle(3)
        attach(app, "down-1-after-3s")
    }

    @MainActor func testDuressThousandTurnSend() throws {
        let app = try open([
            "CMUX_MOBILE_LIST_SCREEN": "chat", "CMUX_MOBILE_LIST_COUNT": "1000", "CMUX_MOBILE_LIST_PASSES": "0",
            "CMUX_MOBILE_LIST_LEAVE_NEWEST": "0", "CMUX_MOBILE_LIST_SETTLE": "1", "CMUX_MOBILE_MOCK_LINK": "slow",
        ], listed: false)
        for index in 0..<5 {
            send(app, "duress send \(index)")
            if index == 0 { attach(app, "duress-0-right-after-tap") }
            settle(3)
        }
        guard let file = Self.traceFile(), let text = try? String(contentsOf: file, encoding: .utf8) else {
            XCTFail("no Documents/send-trace.txt in the simulator's app containers")
            return
        }
        let trace = XCTAttachment(string: text)
        trace.name = "optimistic-trace-duress.txt"
        trace.lifetime = .keepAlways
        add(trace)
    }

    // MARK: - Steps

    @MainActor
    private func open(_ environment: [String: String], listed: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LOAD_PROBE"] = "1"
        app.launchEnvironment["CMUX_MOBILE_SEND_TRACE"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        if listed { app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"] }
        app.launch()
        if listed {
            let row = app.buttons["workspace.row.ws-cmux"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the ws-cmux row")
            row.tap()
        }
        XCTAssertTrue(Self.field(app).waitForExistence(timeout: 90), "the chat composer\n\(app.debugDescription)")
        settle(listed ? 3 : 6)
        return app
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = Self.field(app)
        if !app.keyboards.firstMatch.exists, field.exists { field.tap() }
        settle(0.6)
        app.typeText(text)
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the Send button")
        settle(0.4)
        send.tap()
    }

    @MainActor
    private static func field(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier IN %@", ["chat.composer.field", "chat.composer.card"])).firstMatch
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The newest `Documents/send-trace.txt` among the simulator's app containers.
    static func traceFile() -> URL? { SnappySendBenchUITests.traceFile() }
}
