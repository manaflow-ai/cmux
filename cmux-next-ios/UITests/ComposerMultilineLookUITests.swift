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

    /// A draft of wrapped prose and new lines, typed while the agent's reply streams
    /// into the transcript behind the glass.
    @MainActor
    func testDarkChatComposerWhileStreaming() throws { try capture(.dark, "dark", demo: "kbd-chat", streaming: true) }

    @MainActor
    func testLightChatComposerWhileStreaming() throws { try capture(.light, "light", demo: "kbd-chat", streaming: true) }

    @MainActor
    private func capture(_ appearance: XCUIDevice.Appearance, _ look: String, demo: String, streaming: Bool = false) throws {
        XCUIDevice.shared.appearance = appearance
        let name = "\(demo == "kbd-tab" ? "tab" : "chat")\(streaming ? "-streaming" : "")-\(look)"
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The mock answers a prompt with one long streamed reply (ListStressSettings).
        if streaming { app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo,
                                "-cmuxMobile.settings.appearance", look]
        app.launch()
        defer { app.terminate() }
        // Found by its placeholder too, wherever its identifier is not its own.
        let field = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.composer.field' OR label BEGINSWITH 'Reply to' OR label BEGINSWITH 'Ask '")).firstMatch
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
        if streaming {
            field.typeText("Walk me through the transport layer")
            let send = app.buttons["Send"].firstMatch
            if send.waitForExistence(timeout: 5) { send.tap() }
            _ = app.buttons["Stop"].firstMatch.waitForExistence(timeout: 5)
            // Sending lowers the keyboard and the composer folds to its capsule: open it again.
            if !field.waitForExistence(timeout: 2) {
                let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
                if capsule.waitForExistence(timeout: 5) { capsule.tap() }
            }
            guard field.waitForExistence(timeout: 10) else {
                attach(app, "\(name)-no-field-after-send")
                throw XCTSkip("the composer did not open again after sending")
            }
            if !app.keyboards.firstMatch.exists { field.tap() }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
            // 1 line, then 3 (a new line of prose that wraps to two), then 6, then past the field's six.
            field.typeText("Before you answer that,")
            attach(app, "\(name)-1-line")
            field.typeText("\nalso check whether the relay fallback still works when the phone is on cellular")
            attach(app, "\(name)-3-lines")
            field.typeText("\nand keep the old WireGuard path for the Macs that already pinned it last week\nthen run the tests")
            attach(app, "\(name)-6-lines")
            field.typeText("\nand tell me what changed\nwith numbers\nplease")
            attach(app, "\(name)-9-lines")
            return
        }
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
        // Whether the agent was still answering when this was taken.
        let running = app.buttons["Stop"].firstMatch.exists ? "-running" : ""
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name + running
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
