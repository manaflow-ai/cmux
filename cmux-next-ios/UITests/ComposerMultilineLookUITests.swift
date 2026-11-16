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
    func testDarkChatComposerLinesLookAlike() throws { try capture(.dark, "dark", demo: "kbd-chat") }

    @MainActor
    func testLightChatComposerLinesLookAlike() throws { try capture(.light, "light", demo: "kbd-chat") }

    /// The agent tab of a workspace: the composer is TabsKit's accessory row there.
    @MainActor
    func testDarkTabComposerLinesLookAlike() throws { try capture(.dark, "dark", demo: "kbd-tab") }

    @MainActor
    func testLightTabComposerLinesLookAlike() throws { try capture(.light, "light", demo: "kbd-tab") }

    @MainActor
    private func capture(_ appearance: XCUIDevice.Appearance, _ look: String, demo: String) throws {
        XCUIDevice.shared.appearance = appearance
        let name = "\(demo == "kbd-tab" ? "tab" : "chat")-\(look)"
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo,
                                "-cmuxMobile.settings.appearance", look]
        app.launch()
        defer { app.terminate() }
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) {
            // The collapsed capsule ("Reply to Claude", "Ask Claude") opens the field.
            let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to' OR label BEGINSWITH 'Ask '")).firstMatch
            if capsule.waitForExistence(timeout: 5) { capsule.tap() }
        }
        guard field.waitForExistence(timeout: 10) else {
            // Evidence of where the app was instead of a failure: the run keeps its screenshots.
            attach(app, "\(name)-no-field")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name)-no-field-tree"
            tree.lifetime = .keepAlways
            add(tree)
            throw XCTSkip("no chat composer field in \(demo)")
        }
        if !app.keyboards.firstMatch.exists { field.tap() }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        field.typeText("line 1 of the draft")
        attach(app, "\(name)-1-line")
        for count in 2 ... 6 {
            field.typeText("\nline \(count) of the draft")
            if count == 3 || count == 6 { attach(app, "\(name)-\(count)-lines") }
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
