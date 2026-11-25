import XCTest

/// Cold launch timing against a paired Mac. The harness supplies workspace ids
/// through `CMUX_MOBILE_UI_CHAT_WORKSPACE` and `CMUX_MOBILE_UI_TERMINAL_WORKSPACE`.
/// No mock auth or synthetic transcript is installed, so the marks measure the
/// live daemon's first content over the configured link.
final class LaunchColdLiveUITests: XCTestCase {
    enum Flow: String { case chat, terminal }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testChatFirstRowCold() throws { try run(.chat) }
    @MainActor func testTerminalFirstRowCold() throws { try run(.terminal) }

    @MainActor
    private func run(_ flow: Flow) throws {
        let environment = ProcessInfo.processInfo.environment
        let key = flow == .chat ? "CMUX_MOBILE_UI_CHAT_WORKSPACE" : "CMUX_MOBILE_UI_TERMINAL_WORKSPACE"
        guard let workspace = environment[key], !workspace.isEmpty else {
            throw XCTSkip("live cold launch needs \(key)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_LAUNCH_MARKS"] = "1"
        app.launchEnvironment["CMUX_MOBILE_UI_WORKSPACE"] = workspace
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore", "-cmux-mobile-term-no-intro"]
        app.launch()

        let row = app.buttons["workspace.row.\(workspace)"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "live workspace row\n\(app.debugDescription)")
        row.tap()
        let mark = flow == .chat ? "chat_first_row_frame" : "terminal_first_row_frame"
        XCTAssertTrue(waitForMark(mark, in: app), "\(mark)\n\(app.debugDescription)")

        let marks = Self.marks(in: app)
        let load = environment["CMUX_MOBILE_DURESS_PROFILE"] ?? "off"
        let net = environment["CMUX_MOBILE_NET_PROFILE"] ?? "off"
        let body = marks.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\":\(String(format: "%.1f", $0.value))" }
            .joined(separator: ",")
        print("LAUNCHCOLDLIVE {\"flow\":\"\(flow.rawValue)\",\"load\":\"\(load)\",\"net\":\"\(net)\",\(body)}")
        let attachment = XCTAttachment(string: "LAUNCHCOLDLIVE {\"flow\":\"\(flow.rawValue)\",\(body)}")
        attachment.name = "launch-cold-live"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForMark(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.marks(in: app)[name] != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    @MainActor
    private static func marks(in app: XCUIApplication) -> [String: Double] {
        let probe = app.staticTexts["debug.launch-marks"]
        guard probe.exists, let data = probe.label.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return object
    }
}
