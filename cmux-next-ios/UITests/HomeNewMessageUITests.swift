import XCTest

/// Home's compose button opens the Mac's New Message as Messages' sheet (user
/// request 2026-11-11). Walks every state with real touches and keeps a
/// screenshot of each (verify/new-message): the demo Home (`-cmux-mobile-demo
/// new-message`) has the Cloud Chief Atlas, the Mac's Chief, Builder and
/// Reviewer, and a demo team. Each test runs in light, then dark.
final class HomeNewMessageUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    enum Look: String, CaseIterable {
        case light, dark
        var device: XCUIDevice.Appearance { self == .dark ? .dark : .light }
    }

    @MainActor
    private func launch(_ demo: String = "new-message", look: Look, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = look.device
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", look.rawValue,
                                "-cmux-mobile-demo", demo] + extra
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 6) { app.buttons["Manaflow"].firstMatch.tap() }
        return app
    }

    @MainActor
    private func openSheet(_ app: XCUIApplication, _ look: Look) -> XCUIElement {
        let compose = app.buttons["home.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 30), "compose button\n\(app.debugDescription)")
        // The demo seeds Home after launch: wait for the Mac's rows.
        _ = app.buttons["home.row.conv-builder"].waitForExistence(timeout: 10)
        attach(app, look, "00-home")
        compose.tap()
        let to = app.textFields["conversation.compose.to"]
        XCTAssertTrue(to.waitForExistence(timeout: 10), "New Message's To: field\n\(app.debugDescription)")
        return to
    }

    /// A1–A4, A8, A9: the sheet, the sections before typing, typed matches, tokens, addresses and refusals.
    @MainActor
    func testSectionsTypingTokensAndRefusals() {
        for look in Look.allCases {
            let app = launch(look: look)
            let to = openSheet(app, look)
            XCTAssertTrue(app.cells["conversation.compose.suggestion.chief:cloud"].waitForExistence(timeout: 10),
                          "the Chiefs before anything is typed\n\(app.debugDescription)")
            XCTAssertTrue(app.cells["conversation.compose.section.Chiefs"].exists, "Chiefs section")
            XCTAssertTrue(app.cells["conversation.compose.action.newChief"].exists, "New Chief row")
            XCTAssertTrue(app.cells["conversation.compose.suggestion.team:user_demo_grace"].waitForExistence(timeout: 5), "the team")
            // N3: two Chiefs named Builder on the same Mac tell apart by their last activity.
            let builders = app.cells.matching(NSPredicate(format: "label == %@", "Builder"))
            XCTAssertEqual(builders.count, 2, "both Builder Chiefs listed")
            if builders.count == 2 {
                let lines = (0..<2).map { builders.element(boundBy: $0).value as? String ?? "" }
                XCTAssertTrue(lines.allSatisfy { $0.contains("Active") }, "look-alike Chiefs get their last activity: \(lines)")
                XCTAssertNotEqual(lines[0], lines[1], "the two Builder rows read differently")
            }
            attach(app, look, "01-sheet-empty-sections")
            // A2: the Team section under the Chiefs (the list scrolls above the message bar).
            app.tables["conversation.compose.suggestions"].swipeUp()
            Self.pause(0.6)
            XCTAssertTrue(app.cells["conversation.compose.section.Team"].isHittable, "Team section on screen")
            attach(app, look, "01b-team-section")
            app.tables["conversation.compose.suggestions"].swipeDown()

            // A3: typing finds by word start.
            to.typeText("ho")
            XCTAssertTrue(app.cells["conversation.compose.suggestion.team:user_demo_grace"].waitForExistence(timeout: 5),
                          "Grace Hopper for \"ho\"\n\(app.debugDescription)")
            XCTAssertFalse(app.cells["conversation.compose.section.Chiefs"].exists, "typing replaces the sections")
            attach(app, look, "02-typed-matches")

            // A4: a pick is a token; the sections stay away while someone is chosen.
            app.cells["conversation.compose.suggestion.team:user_demo_grace"].tap()
            XCTAssertTrue(app.buttons["conversation.compose.token.c:team:user_demo_grace"].waitForExistence(timeout: 5)
                          || app.otherElements["conversation.compose.token.c:team:user_demo_grace"].exists,
                          "Grace's token\n\(app.debugDescription)")
            attach(app, look, "03-token-blank-page")

            // A3: a typed email: the address row, then Invite … to Manaflow.
            to.typeText("new.person@example.com")
            XCTAssertTrue(app.cells["conversation.compose.suggestion.address:new.person@example.com"].waitForExistence(timeout: 5),
                          "the address row\n\(app.debugDescription)")
            XCTAssertTrue(app.cells["conversation.compose.action.inviteToTeam:new.person@example.com"].exists, "Invite to the team row")
            attach(app, look, "04-typed-email-invite")
            app.cells["conversation.compose.action.inviteToTeam:new.person@example.com"].tap()
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Invite asks first")
            attach(app, look, "05-invite-to-team-confirm")
            app.alerts.firstMatch.buttons["Cancel"].tap()

            // Clear the typed address; then A4: Backspace on an empty field selects Grace, the next deletes her.
            clearTo(to)
            to.typeText(XCUIKeyboardKey.delete.rawValue)
            let grace = app.descendants(matching: .any)["conversation.compose.token.c:team:user_demo_grace"].firstMatch
            XCTAssertTrue(grace.exists, "Grace still a token after the first Backspace")
            XCTAssertTrue(grace.isSelected, "the first Backspace selects the last token")
            attach(app, look, "05b-backspace-selects-token")
            to.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertFalse(grace.waitForExistence(timeout: 1), "the second Backspace deletes it")
            attach(app, look, "05c-backspace-deletes-token")

            // A4: Return on a name nobody has is a red token; A8: Send then says why under To:.
            to.typeText("zzz\n")
            attach(app, look, "06-red-token")
            let body = app.textViews["conversation.composer.text"]
            body.tap()
            body.typeText("Hello")
            app.buttons["conversation.composer.send"].tap()
            let notice = app.staticTexts["conversation.compose.notice"]
            XCTAssertTrue(notice.waitForExistence(timeout: 5), "the refusal line\n\(app.debugDescription)")
            XCTAssertTrue(notice.label.contains("zzz"), "names the red token: \(notice.label)")
            attach(app, look, "07-refusal-red-token")

            // A8: a Mac Chief and a teammate cannot be a Cloud group.
            to.tap()
            to.typeText(XCUIKeyboardKey.delete.rawValue)
            to.typeText(XCUIKeyboardKey.delete.rawValue)
            to.typeText("Builder")
            app.cells["conversation.compose.suggestion.chief:mac:conv-builder"].firstMatch.tap()
            to.typeText("Ada")
            app.cells["conversation.compose.suggestion.team:user_demo_ada"].firstMatch.tap()
            body.tap()
            app.buttons["conversation.composer.send"].tap()
            XCTAssertTrue(notice.waitForExistence(timeout: 5), "the group refusal line\n\(app.debugDescription)")
            attach(app, look, "08-refusal-mac-chief-group")

            // A9: the X closes New Message; nothing was sent.
            app.buttons["conversation.compose.cancel"].tap()
            XCTAssertTrue(app.buttons["home.compose"].waitForExistence(timeout: 5), "back on Home")
            attach(app, look, "09-closed")
            app.terminate()
        }
    }

    /// A5, A6: one Chief chosen shows its conversation under To:; a send there opens it on Home.
    @MainActor
    func testExistingChiefConversationAndSend() {
        for look in Look.allCases {
            let app = launch(look: look)
            let to = openSheet(app, look)
            // Typed text in the sheet's composer moves into the Chief's own message box.
            let body = app.textViews["conversation.composer.text"].firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 5))
            body.tap()
            body.typeText("Status of the nightly?")
            attach(app, look, "10-body-typed-before-recipient")
            to.tap()
            XCTAssertTrue(app.cells["conversation.compose.suggestion.chief:cloud"].waitForExistence(timeout: 5)
                          || { to.typeText("Atlas"); return app.cells["conversation.compose.suggestion.chief:cloud"].waitForExistence(timeout: 5) }(),
                          "Atlas row\n\(app.debugDescription)")
            app.cells["conversation.compose.suggestion.chief:cloud"].tap()
            let existing = app.otherElements["conversation.compose.existing"]
            XCTAssertTrue(existing.waitForExistence(timeout: 10), "Atlas's conversation under To:\n\(app.debugDescription)")
            Self.pause(1.5)
            attach(app, look, "11-existing-chief-conversation")
            // Remove the token (the Chief's message box took the keyboard): tap it, then Delete.
            let token = app.descendants(matching: .any)["conversation.compose.token.c:chief:cloud"].firstMatch
            if token.exists { token.tap() } else { to.tap() }
            app.typeText(XCUIKeyboardKey.delete.rawValue)
            if app.otherElements["conversation.compose.existing"].exists { app.typeText(XCUIKeyboardKey.delete.rawValue) }
            Self.pause(0.8)
            attach(app, look, "12-token-removed-blank-page")
            app.typeText("Atlas")
            app.cells["conversation.compose.suggestion.chief:cloud"].firstMatch.tap()
            XCTAssertTrue(existing.waitForExistence(timeout: 10))
            Self.pause(1.0)
            // Send in the Chief's own message box.
            let send = existing.buttons["conversation.composer.send"].firstMatch
            let field = existing.textViews["conversation.composer.text"].firstMatch
            // The text typed before the token moved with it and came back after it (the box's
            // value is its placeholder while empty).
            XCTAssertTrue((field.value as? String ?? "").contains("nightly"),
                          "the typed text stayed through the token's removal: \(field.value ?? "")")
            if !(field.value as? String ?? "").contains("nightly") {
                field.tap()
                field.typeText("Status of the nightly?")
            }
            // Send shows once the field holds the text (empty, the same slot is the microphone).
            _ = field.waitForExistence(timeout: 5)
            let typed = expectation(for: NSPredicate(format: "value CONTAINS %@", "nightly"), evaluatedWith: field)
            _ = XCTWaiter().wait(for: [typed], timeout: 5)
            attach(app, look, "13-existing-typed")
            // The bottom edge: drag the transcript down a little so its newest bubbles sit behind the
            // message box (the soft scroll edge effect there), then let it settle.
            let transcript = existing.collectionViews.firstMatch
            if transcript.exists {
                transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                Self.pause(0.8)
                attach(app, look, "13b-under-message-box")
            }
            if send.waitForExistence(timeout: 5) { send.tap() }
            // The sheet goes; the Chief conversation is on Home with the message.
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Status of the nightly?")).firstMatch
                .waitForExistence(timeout: 10), "the message in the Chief conversation\n\(app.debugDescription)")
            XCTAssertFalse(app.textFields["conversation.compose.to"].exists, "New Message closed")
            Self.pause(1.0)
            attach(app, look, "14-sent-chief-conversation-on-home")
            // The same bottom edge on Home's Chief screen.
            let homeTranscript = app.collectionViews.firstMatch
            if homeTranscript.exists {
                homeTranscript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.05, thenDragTo: homeTranscript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                Self.pause(0.8)
                attach(app, look, "14b-home-under-message-box")
            }
            app.terminate()
        }
    }

    /// A7, A8: a teammate on the blank page; Send with nobody in To:.
    @MainActor
    func testBlankPageSendAndNobodyInTo() {
        for look in Look.allCases {
            let app = launch(look: look)
            let to = openSheet(app, look)
            let body = app.textViews["conversation.composer.text"].firstMatch
            body.tap()
            body.typeText("Lunch?")
            app.buttons["conversation.composer.send"].tap()
            let notice = app.staticTexts["conversation.compose.notice"]
            XCTAssertTrue(notice.waitForExistence(timeout: 5), "Add someone in To: first.\n\(app.debugDescription)")
            // A8: the line is seen, above the Chiefs list (never under it).
            XCTAssertTrue(notice.isHittable, "the refusal line is on screen")
            let firstSection = app.cells["conversation.compose.section.Chiefs"]
            if firstSection.exists {
                XCTAssertLessThanOrEqual(notice.frame.maxY, firstSection.frame.minY + 1, "the list starts under the refusal line")
            }
            attach(app, look, "15-refusal-nobody-in-to")
            to.typeText("Grace")
            app.cells["conversation.compose.suggestion.team:user_demo_grace"].firstMatch.tap()
            XCTAssertFalse(app.otherElements["conversation.compose.existing"].waitForExistence(timeout: 1.5),
                           "a teammate starts on the blank page")
            attach(app, look, "16-teammate-blank-page")
            body.tap()
            app.buttons["conversation.composer.send"].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Lunch?")).firstMatch
                .waitForExistence(timeout: 10), "the new conversation with its first message\n\(app.debugDescription)")
            // A new conversation with Grace: her name, only the first message, no Chief in it.
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "BUILD SUCCEEDED")).firstMatch.exists,
                           "no Chief transcript in a new conversation with a teammate")
            XCTAssertFalse(app.alerts.firstMatch.exists, "no Chief alert prompt for a conversation with people")
            Self.pause(1.0)
            attach(app, look, "17-sent-new-conversation")
            app.terminate()
        }
    }

    /// A10, N1, N2: New Chief's prompt; the Mac-only account (Mac Chief first, Invite for a team of one).
    @MainActor
    func testNewChiefAndMacOnlyInvite() {
        for look in Look.allCases {
            var app = launch(look: look)
            _ = openSheet(app, look)
            let newChief = app.cells["conversation.compose.action.newChief"]
            XCTAssertTrue(newChief.waitForExistence(timeout: 10), "New Chief row\n\(app.debugDescription)")
            newChief.tap()
            XCTAssertTrue(app.alerts["New Chief"].waitForExistence(timeout: 8), "New Chief's prompt on Home\n\(app.debugDescription)")
            attach(app, look, "18-new-chief-prompt")
            app.alerts["New Chief"].buttons["Cancel"].tap()
            app.terminate()

            app = launch("new-message-mac-only", look: look)
            _ = openSheet(app, look)
            let macChief = app.cells["conversation.compose.suggestion.chief:mac"]
            XCTAssertTrue(macChief.waitForExistence(timeout: 10), "the Mac Chief leads\n\(app.debugDescription)")
            XCTAssertTrue((macChief.value as? String ?? "").contains("Main"), "tagged Main: \(macChief.value ?? "")")
            let invite = app.cells["conversation.compose.action.invite"]
            XCTAssertTrue(invite.waitForExistence(timeout: 5), "Invite for a team of one\n\(app.debugDescription)")
            // N2: the Invite row on screen (the list scrolls above the message bar).
            if !invite.isHittable { app.tables["conversation.compose.suggestions"].swipeUp() }
            Self.pause(0.6)
            XCTAssertTrue(invite.isHittable, "the Invite row is on screen")
            attach(app, look, "19-mac-only-invite")
            invite.tap()
            // The share sheet up (its list of apps), not mid-animation.
            let share = app.otherElements["ActivityListView"].firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 8) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2),
                          "the Invite share sheet\n\(app.debugDescription)")
            Self.pause(1.0)
            attach(app, look, "20-invite-share-sheet")
            // Every app the system offers for the link (the share sheet's More).
            let more = app.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 3) {
                more.tap()
                Self.pause(1.5)
                attach(app, look, "20b-invite-share-more")
            }
            app.terminate()
        }
    }

    /// L4: the largest accessibility text size: rows grow with the text and never overlap.
    @MainActor
    func testAccessibilityTextSize() {
        let app = launch(look: .light, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        _ = openSheet(app, .light)
        // The system's one-time slide-to-type tip covers the keyboard on a fresh simulator.
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        let atlas = app.cells["conversation.compose.suggestion.chief:cloud"]
        let chief = app.cells["conversation.compose.suggestion.chief:mac"]
        XCTAssertTrue(atlas.waitForExistence(timeout: 10) && chief.exists, "rows at AX size\n\(app.debugDescription)")
        XCTAssertGreaterThan(atlas.frame.height, 80, "the row grew with the text: \(atlas.frame)")
        XCTAssertLessThanOrEqual(atlas.frame.maxY, chief.frame.minY + 1, "rows do not overlap")
        Self.pause(1.0)
        attach(app, .light, "21-ax5-sheet")
        app.terminate()
    }

    /// A11: Forward from a Chief's select mode opens the same New Message, with the draft.
    @MainActor
    func testForwardOpensNewMessage() {
        for look in Look.allCases {
            let app = launch("new-message-forward", look: look)
            let to = app.textFields["conversation.compose.to"]
            XCTAssertTrue(to.waitForExistence(timeout: 30), "New Message from Forward\n\(app.debugDescription)")
            XCTAssertTrue(app.cells["conversation.compose.section.Chiefs"].waitForExistence(timeout: 10), "the Mac's sections")
            let body = app.textViews["conversation.composer.text"].firstMatch
            XCTAssertFalse((body.value as? String ?? "").isEmpty, "the forwarded text is the draft")
            Self.pause(0.8)
            attach(app, look, "22-forward-new-message")
            app.terminate()
        }
    }

    // MARK: Helpers

    private func clearTo(_ field: XCUIElement) {
        let text = field.value as? String ?? ""
        guard !text.isEmpty, text != "To:" else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    static func pause(_ seconds: Double) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    private func attach(_ app: XCUIApplication, _ look: Look, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(look.rawValue)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
