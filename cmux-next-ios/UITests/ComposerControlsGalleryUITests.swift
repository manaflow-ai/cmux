import XCTest

/// Leo, 2026-11-22: "QUESTION THE PAPERCLIP ... WHY HAVE A VOICE BUTTON IN THE TERMINAL? ... im hiding
/// this by default ... the attachments are just the most awkward shit in this case because in the common
/// case of 1, you get corner to corner tension instead of it simply being where it should be."
///
/// The composer's controls, each one checked and shot (`composer-*` attachments): + (not a
/// paperclip) first, no voice button unless turned on, the field taking the freed width, and one
/// attachment inside the field where the text starts. The reasons, with sources:
/// cmuxterm-hq docs/design/ios-composer-controls.md.
final class ComposerControlsGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String], env: [String: String] = [:], dark: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment.merge(env) { $1 }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-AppleInterfaceStyle", dark ? "Dark" : "Light"] + arguments
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Default: + then the field, which runs to the screen's edge; no voice, no paperclip.
    @MainActor
    func testDefaultComposerIsPlusAndField() {
        for dark in [true, false] {
            let app = launch(["-cmux-mobile-demo", "voice-terminal"], dark: dark)
            let attach = app.buttons["terminal.composer.attach"]
            XCTAssertTrue(attach.waitForExistence(timeout: 30), "the + shows\n\(app.debugDescription)")
            XCTAssertEqual(attach.label, "Add Attachment")
            XCTAssertFalse(app.buttons["terminal.composer.voice"].exists, "no voice button by default")
            let send = app.buttons["terminal.composer.send"]
            XCTAssertTrue(send.exists)
            // The field starts right after +: nothing between them.
            let gap = send.frame.minX - attach.frame.maxX
            XCTAssertGreaterThan(gap, app.frame.width * 0.55, "the field takes the width beside +: gap \(gap)")
            shoot(app, "default-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// One picked photo sits inside the field, starting where the text starts, not at the
    /// screen's corner opposite send.
    @MainActor
    func testOneAttachmentSitsWhereTheTextStarts() {
        for dark in [true, false] {
            let app = launch(["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "oneattachment"], dark: dark)
            let tile = app.descendants(matching: .any)["terminal.attachment"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 40), "the attachment shows\n\(app.debugDescription)")
            sleep(4)
            // The + is a Menu: match it as any element, and never skip the placement check when it is missing.
            let attach = app.descendants(matching: .any)["terminal.composer.attach"].firstMatch
            XCTAssertTrue(attach.exists, "the + shows\n\(app.debugDescription)")
            XCTAssertGreaterThan(tile.frame.minX, attach.frame.maxX, "the tile is inside the field, right of +")
            // The composer's own text view: `textViews.firstMatch` is the terminal's, far offscreen.
            let field = app.textViews["terminal.composer.field"]
            XCTAssertTrue(field.exists, "the composer field shows\n\(app.debugDescription)")
            if field.exists {
                XCTAssertLessThan(abs(tile.frame.minX - field.frame.minX), 16, "the tile starts where the text starts")
                XCTAssertLessThan(tile.frame.maxY, field.frame.minY + 4, "the tile sits above the draft")
            }
            shoot(app, "one-attachment-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// Every placement but Off (Leo, 2026-11-23: "should be maybe 4. side of the send button. left
    /// if always showing? idk, whatever chatgpt/claude do."), each checked and shot:
    /// "In Send Button" (the empty draft's send circle is voice), "Beside Send" (voice just left of
    /// send, which stays send) and "Left of Field" (its own circle after +).
    static let placements = ["sendButton", "besideSend", "leading"]

    @MainActor
    func testVoiceWhenTurnedOn() {
        for placement in Self.placements {
            for dark in [true, false] {
                let app = launch(["-cmux-mobile-demo", "voice-terminal", "-composer.voiceButton", placement], dark: dark)
                let voice = app.buttons["terminal.composer.voice"]
                XCTAssertTrue(voice.waitForExistence(timeout: 30), "\(placement): voice shows\n\(app.debugDescription)")
                let send = app.buttons["terminal.composer.send"]
                XCTAssertEqual(send.exists, placement != "sendButton",
                               "\(placement): the send circle is voice only for In Send Button")
                let attach = app.descendants(matching: .any)["terminal.composer.attach"].firstMatch
                if placement == "besideSend", send.exists {
                    XCTAssertLessThan(voice.frame.maxX, send.frame.minX + 2, "besideSend: voice sits left of send")
                    XCTAssertLessThan(send.frame.minX - voice.frame.maxX, 24, "besideSend: right beside it")
                    if attach.exists {
                        XCTAssertGreaterThan(voice.frame.minX - attach.frame.maxX, app.frame.width * 0.4,
                                             "besideSend: the field keeps its width")
                    }
                }
                if placement == "leading", attach.exists {
                    XCTAssertLessThan(attach.frame.midX, voice.frame.midX, "leading: + comes first")
                    XCTAssertLessThan(voice.frame.maxX, app.frame.width * 0.4, "leading: left of the field")
                }
                shoot(app, "voice-\(placement)-\(dark ? "dark" : "light")")
                app.terminate()
            }
        }
    }

    /// The agent chat's composer reads the same setting: each placement, checked and shot.
    @MainActor
    func testAgentChatVoiceWhenTurnedOn() {
        for placement in Self.placements {
            let app = launch(["-cmux-mobile-demo", "voice-chat", "-composer.voiceButton", placement])
            // The agent chat shows its composer collapsed ("Reply to ...") until tapped.
            let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
            if capsule.waitForExistence(timeout: 30) { capsule.tap() }
            let field = app.textViews["chat.composer.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 30), "\(placement): the composer shows\n\(app.debugDescription)")
            let voice = app.buttons["agentChat.composer.voice"]
            XCTAssertTrue(voice.waitForExistence(timeout: 10), "\(placement): voice shows\n\(app.debugDescription)")
            let send = app.buttons["agentChat.composer.send"]
            XCTAssertEqual(send.exists, placement != "sendButton",
                           "\(placement): the empty draft's send circle is voice only for In Send Button")
            if placement == "besideSend", send.exists {
                XCTAssertLessThan(voice.frame.maxX, send.frame.minX + 2, "besideSend: voice sits left of send")
                XCTAssertLessThan(send.frame.minX - voice.frame.maxX, 24, "besideSend: right beside it")
            }
            shoot(app, "agent-voice-\(placement)")
            app.terminate()
        }
    }

    /// The setting itself: Settings → Composer → Voice Mode → Voice Button, Off.
    @MainActor
    func testVoiceSettingIsOffByDefault() {
        let app = launch(["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "composer"])
        let picker = app.descendants(matching: .any)["settings.composer.voiceButton"].firstMatch
        for _ in 0..<4 where !picker.exists { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the Voice Button setting shows\n\(app.debugDescription)")
        XCTAssertTrue(picker.label.contains("Off") || (picker.value as? String)?.contains("Off") == true,
                      "off by default: \(picker.label) \(String(describing: picker.value))")
        shoot(app, "setting")
        // The menu lists all four choices.
        picker.tap()
        for title in ["Off", "In Send Button", "Beside Send", "Left of Field"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "the menu offers \(title)\n\(app.debugDescription)")
        }
        shoot(app, "setting-choices")
        app.terminate()
    }
}
