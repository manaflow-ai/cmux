import XCTest

/// The App Review notes, walked as a reviewer walks them, with no test switch: a real email-code
/// sign-in as the review account (`cmux-rev-0e6ba145@mailinator.com`, the code read from its public
/// Mailinator inbox), the first-launch steps, Chief from Home, then the simulated MacBook Pro: the
/// Workspaces tab, a workspace's terminal answering typed commands, and its browser tab's page.
/// The demo comes from the account itself (its address), so this checks the gate a shipping build
/// uses. It needs the network (sign-in, the inbox, the page); run it by name only
/// (`ui=ReviewNotesFlowUITests`). Each step is attached as a screenshot.
final class ReviewNotesFlowUITests: XCTestCase {
    private static let account = "cmux-rev-0e6ba145@mailinator.com"
    private static let inbox = URL(string: "https://www.mailinator.com/api/v2/domains/public/inboxes/cmux-rev-0e6ba145")!

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTheReviewerNotesFlow() throws {
        let app = XCUIApplication()
        // A fresh install starts signed out, as the reviewer's does.
        app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        // Sign in, step 1: "Continue with email", the address, "Continue".
        let withEmail = app.buttons["Continue with email"].firstMatch
        XCTAssertTrue(withEmail.waitForExistence(timeout: 40), "the welcome offers email sign-in\n\(app.debugDescription)")
        attach(app, "01-welcome")
        withEmail.tap()
        let emailField = app.textFields["Email"].firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "What's your email?\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["What's your email?"].exists)
        emailField.tap()
        emailField.typeText(Self.account)
        attach(app, "02-email")
        let sentAfter = Date().addingTimeInterval(-30)
        let continueButton = app.buttons.matching(NSPredicate(format: "label == 'Continue'")).allElementsBoundByIndex.last
        XCTAssertNotNil(continueButton, "the sheet's Continue")
        continueButton?.tap()

        // Step 2 and 3: "Check your email", the code from the public inbox.
        XCTAssertTrue(app.staticTexts["Check your email"].waitForExistence(timeout: 30), "the code step\n\(app.debugDescription)")
        attach(app, "03-check-email")
        let code = try XCTUnwrap(Self.code(after: sentAfter), "no sign-in code reached the public inbox in time")
        let codeField = app.textFields["Code"].firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "the code field\n\(app.debugDescription)")
        // A fresh simulator covers its first letter keyboard with the "slide to type" tip.
        let slideTip = app.buttons["Continue"].firstMatch
        if app.keyboards.firstMatch.waitForExistence(timeout: 5), slideTip.waitForExistence(timeout: 2),
           !app.staticTexts["What's your email?"].exists { slideTip.tap() }
        codeField.typeText(code)

        // First launch: notifications ("Not now"); the review account has one space and an online
        // Mac, so neither "Choose a space" nor "Connect your Mac" should show.
        let tabBar = app.tabBars.firstMatch
        let notNow = app.buttons["Not now"].firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !tabBar.exists, Date() < deadline {
            if notNow.exists { attach(app, "04-first-launch-step"); notNow.tap() }
            _ = tabBar.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(tabBar.exists, "signed in, the shell shows\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Connect your Mac"].exists, "the review account needs no Mac pairing")
        attach(app, "05-home")

        // Review path: Chief from Home, a message, an answer.
        app.tabBars.buttons["Home"].tap()
        let chief = app.descendants(matching: .any)["home.chief"]
        if chief.waitForExistence(timeout: 20) {
            chief.tap()
            let field = app.textViews["conversation.composer.text"]
            if field.waitForExistence(timeout: 20) {
                field.tap()
                field.typeText("What can you help me with?")
                app.buttons["conversation.composer.send"].tap()
                attach(app, "06-chief-sent")
                let answer = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'conversation.message.' AND label BEGINSWITH 'Chief'")).firstMatch
                let answered = answer.waitForExistence(timeout: 60)
                attach(app, "07-chief-answer")
                XCTAssertTrue(answered, "Chief answers in the conversation\n\(app.debugDescription)")
            } else {
                XCTFail("Chief opens with a message box\n\(app.debugDescription)")
            }
            app.navigationBars.buttons.firstMatch.tap()
        } else {
            XCTFail("Home shows Chief\n\(app.debugDescription)")
        }

        // Simulated Mac, step 1: the Workspaces tab lists the MacBook Pro's three workspaces.
        app.tabBars.buttons["Workspaces"].tap()
        let website = app.buttons["workspace.row.review-ws-web"]
        XCTAssertTrue(website.waitForExistence(timeout: 30), "website\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["workspace.row.review-ws-api"].exists, "api-server")
        XCTAssertTrue(app.buttons["workspace.row.review-ws-notes"].exists, "notes")
        attach(app, "08-workspaces")

        // Step 2: website's terminal shows recent commands and answers ls, git status and htop.
        website.tap()
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the terminal\n\(app.debugDescription)")
        attach(app, "09-terminal")
        // The terminal's text is drawn, not exposed to accessibility: each answer is a screenshot
        // (and CmuxMobileTerminalTests check the shell's answers themselves).
        for (index, command) in ["ls", "git status", "htop"].enumerated() {
            field.tap()
            field.typeText(command)
            app.buttons["terminal.composer.send"].tap()
            settle(seconds: 2)
            attach(app, "1\(index)-terminal-\(command.replacingOccurrences(of: " ", with: "-"))")
        }
        field.tap()
        field.typeText("q")
        app.buttons["terminal.composer.send"].tap()

        // Step 3: Tabs, then the cmux tab; the page opens in the app.
        let keyboardKey = app.buttons["terminal.key.keyboard"]
        if app.keyboards.firstMatch.exists, keyboardKey.exists { keyboardKey.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        let tabs = app.buttons["Tabs"].firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), "Tabs\n\(app.debugDescription)")
        tabs.tap()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'cmux' AND label ENDSWITH ', tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the cmux tab\n\(app.debugDescription)")
        attach(app, "13-tabs")
        card.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20), "the page opens in the app\n\(app.debugDescription)")
        let loaded = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'terminal'")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30), "cmux.com loaded\n\(app.debugDescription)")
        attach(app, "14-browser")
    }

    /// The newest sign-in code sent to the review inbox after `date`: its subject ends with the code.
    private static func code(after date: Date) -> String? {
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            if let data = try? Data(contentsOf: inbox),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let messages = object["msgs"] as? [[String: Any]] {
                let fresh = messages.compactMap { message -> (Double, String)? in
                    guard let time = message["time"] as? Double, time / 1000 >= date.timeIntervalSince1970,
                          let subject = message["subject"] as? String,
                          let word = subject.split(separator: " ").last,
                          word.count == 6, word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
                    return (time, String(word))
                }
                if let newest = fresh.max(by: { $0.0 < $1.0 }) { return newest.1 }
            }
            // The inbox has no push: read it again in a few seconds (bounded by the deadline above).
            Thread.sleep(forTimeInterval: 5)
        }
        return nil
    }

    /// A bounded pause for a screenshot of drawn output, which has no accessibility signal.
    @MainActor
    private func settle(seconds: Double) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
