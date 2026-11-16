import XCTest

/// Leo, 2026-11-16: "the ios thing it turns pale in the composer after 3 lines".
/// Screenshots of the agent chat's composer with a 1-, 3- and 6-line draft, in
/// dark and light: the before/after evidence that a longer draft's text looks
/// like a one-line draft's.
final class ComposerMultilineLookUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testDarkChatComposerLinesLookAlike() throws { try capture(.dark, "dark") }

    @MainActor
    func testLightChatComposerLinesLookAlike() throws { try capture(.light, "light") }

    @MainActor
    private func capture(_ appearance: XCUIDevice.Appearance, _ name: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat",
                                "-cmuxMobile.settings.appearance", name]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
        field.typeText("line 1 of the draft")
        attach(app, "chat-\(name)-1-line")
        for count in 2 ... 6 {
            field.typeText("\nline \(count) of the draft")
            if count == 3 || count == 6 { attach(app, "chat-\(name)-\(count)-lines") }
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        // The field settles (its height animates on the composer's spring).
        _ = app.wait(for: .runningForeground, timeout: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
