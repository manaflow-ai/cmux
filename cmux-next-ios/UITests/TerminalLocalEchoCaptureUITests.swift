import XCTest

/// Screenshots of predictive local echo for review (cmux#43258): the mock
/// shell answers each key a long round trip later (`-cmux-mobile-term-rtt-ms`),
/// a command runs so the engine learns the prompt, and the first key of the
/// next command is captured right after the press (drawn, underlined, before
/// the echo) and again after its echo arrives.
final class TerminalLocalEchoCaptureUITests: XCTestCase {
    private static let roundTripMs = 1500

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstKeyAtAKnownPromptDrawsBeforeTheEcho() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += [
            "-cmuxMobile.setupComplete", "YES",
            "-cmuxMobile.settings.predictiveEcho", "YES",
            "-cmux-mobile-term-rtt-ms", String(Self.roundTripMs),
            "-cmux-mobile-demo", "ws-terminal-idle",
        ]
        app.launch()

        let keyboardKey = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 20), "keyboard key\n\(app.debugDescription)")
        // The mock shell's intro (ls, git log, a build) runs first.
        Self.pause(20)
        keyboardKey.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "terminal keyboard\n\(app.debugDescription)")
        attach(app, "1-prompt")

        // A first command: two echoes arm the engine, which learns the prompt.
        app.typeText("ls")
        Self.pause(Double(Self.roundTripMs) / 1000 * 2 + 1)
        app.typeText("\r")
        Self.pause(Double(Self.roundTripMs) / 1000 * 2 + 1)
        attach(app, "2-after-ls")

        // The first key of the next command, at the prompt the shell printed.
        app.typeText("e")
        attach(app, "3-first-key-before-echo")
        Self.pause(Double(Self.roundTripMs) / 1000 + 1)
        attach(app, "4-first-key-after-echo")
    }

    private static func pause(_ seconds: Double) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
