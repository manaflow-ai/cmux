import XCTest

/// All-UI-states capture, part 2: Home, the Chief conversation and its
/// pages, Cloud chats, and Chief calls. See `UIStateCapture.swift`.
final class AllUIStatesHomeCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let homeRows = ["CMUX_MOBILE_LIST_SCREEN": "home", "CMUX_MOBILE_LIST_COUNT": "16", "CMUX_MOBILE_LIST_PASSES": "0"]

    @MainActor
    func testHome() {
        let g = "3 Home"
        capture([
            Scene(group: g, id: "home-mock-chief", args: ["-cmux-mobile-tab", "home"]),
            Scene(group: g, id: "home-rows-and-pins", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4),
            Scene(group: g, id: "home-row-swipe-actions", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.swipeLeft(app.descendants(matching: .any)["home.row.stress-5"].firstMatch, "home row stress-5")
            },
            Scene(group: g, id: "home-row-swipe-right", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.swipeRight(app.descendants(matching: .any)["home.row.stress-5"].firstMatch, "home row stress-5")
            },
            Scene(group: g, id: "home-row-context-menu", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.longPress(app.descendants(matching: .any)["home.row.stress-5"].firstMatch, "home row stress-5")
            },
            Scene(group: g, id: "home-delete-confirm", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.steps([
                    { C.longPress(app.descendants(matching: .any)["home.row.stress-5"].firstMatch, "home row stress-5") },
                    { C.tap(C.any(app, "home.row.delete"), "Delete item") },
                ])
            },
            Scene(group: g, id: "home-show-hidden", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.steps([
                    { C.longPress(app.descendants(matching: .any)["home.row.stress-5"].firstMatch, "home row stress-5") },
                    { C.tap(C.any(app, "home.row.delete"), "Delete item") },
                    { C.tap(C.any(app, "home.delete.confirm"), "Delete confirm") },
                    { C.wait(C.any(app, "home.showHidden"), "Show hidden row", timeout: 6) },
                ])
            },
            Scene(group: g, id: "home-unread-filter-empty", args: ["-cmux-mobile-tab", "home"]) { app in
                C.tap(C.any(app, "home.unread"), "unread filter")
            },
            Scene(group: g, id: "home-unread-filter-rows", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                C.tap(C.any(app, "home.unread"), "unread filter")
            },
            Scene(group: g, id: "home-search", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                app.swipeDown()
                let field = app.searchFields.firstMatch
                return C.steps([
                    { C.showKeyboard(app, field: field, "search field") },
                    { app.typeText("stress 1"); return nil },
                ])
            },
            Scene(group: g, id: "home-search-no-results", args: ["-cmux-mobile-tab", "home"], env: Self.homeRows, settle: 4) { app in
                app.swipeDown()
                return C.steps([
                    { C.showKeyboard(app, field: app.searchFields.firstMatch, "search field") },
                    { app.typeText("zzqqxx"); return nil },
                ])
            },
            Scene(group: g, id: "home-mac-filter-menu", args: ["-cmux-mobile-tab", "home"]) { app in
                C.tap(C.any(app, "home.mac"), "Show Home of menu")
            },
            Scene(group: g, id: "home-couldnt-load-retry", args: ["-cmux-mobile-recovery-gallery", "home"]),
            Scene(group: g, id: "home-cloud-and-mac-chief", args: ["-cmux-mobile-demo", "call-scope-home"], settle: 4),
            Scene(group: g, id: "home-cloud-chief-menu", args: ["-cmux-mobile-demo", "call-scope-home"], settle: 4) { app in
                C.longPress(C.any(app, "home.chief"), "Cloud Chief row")
            },
            Scene(group: g, id: "cloud-chats-no-mac", args: ["-cmux-mobile-tab", "home"]) { app in
                C.tap(app.buttons["Cloud chats"].firstMatch, "Cloud chats button")
            },
            Scene(group: g, id: "cloud-chats-gallery", args: ["-cmux-mobile-recovery-gallery", "cloud"]),
            Scene(group: g, id: "cloud-chats-gallery-scrolled", args: ["-cmux-mobile-recovery-gallery", "cloud"]) { app in
                C.scrollDown(app, times: 2)
            },
        ])
    }

    @MainActor
    func testChief() {
        let g = "4 Chief"
        capture([
            Scene(group: g, id: "chief-conversation", args: ["-cmux-mobile-demo", "chief-open"], settle: 5),
            Scene(group: g, id: "chief-compose-keyboard", args: ["-cmux-mobile-tab", "home"]) { app in
                C.tap(C.any(app, "home.compose"), "compose button")
            },
            Scene(group: g, id: "chief-draft-typed", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.steps([
                    { C.showKeyboard(app, field: app.textViews["conversation.composer.text"], "Chief composer") },
                    { app.typeText("Can you check the nightly build and tell me what broke?"); return nil },
                ])
            },
            Scene(group: g, id: "chief-long-draft", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.steps([
                    { C.showKeyboard(app, field: app.textViews["conversation.composer.text"], "Chief composer") },
                    { app.typeText(String(repeating: "A long message that wraps over many lines in the composer. ", count: 8)); return nil },
                ])
            },
            Scene(group: g, id: "chief-sent-typing", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.steps([
                    { C.showKeyboard(app, field: app.textViews["conversation.composer.text"], "Chief composer") },
                    { app.typeText("Status?"); return nil },
                    { C.tap(app.buttons["conversation.composer.send"], "send") },
                ])
            },
            Scene(group: g, id: "chief-demo", args: ["-cmux-mobile-demo", "chief"], settle: 0,
                  frames: [("chief-demo-opened", 6.0), ("chief-demo-reply", 12.0), ("chief-demo-tapback", 17.0)]),
            Scene(group: g, id: "chief-parity", args: ["-cmux-mobile-demo", "chief-parity"], settle: 0,
                  frames: [("chief-compose-up", 5.0), ("chief-photo-attach", 11.0), ("chief-photos-drawer", 15.0)]),
            Scene(group: g, id: "chief-message-actions", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.longPress(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'conversation.message.'")).element(boundBy: 2), "a message")
            },
            Scene(group: g, id: "chief-reply-thread", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                let quote = app.descendants(matching: .any)["conversation.message.msg_local_7"].firstMatch
                guard quote.waitForExistence(timeout: 10) else { return "no message msg_local_7" }
                _ = C.swipeRight(quote, "message")
                if app.otherElements["conversation.replyThread"].waitForExistence(timeout: 3) { return nil }
                _ = C.swipeLeft(quote, "message")
                return C.wait(app.otherElements["conversation.replyThread"], "reply thread", timeout: 5)
            },
            Scene(group: g, id: "chief-plus-menu", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.tap(C.any(app, "conversation.composer.plus"), "composer plus")
            },
            Scene(group: g, id: "chief-send-effects", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.steps([
                    { C.showKeyboard(app, field: app.textViews["conversation.composer.text"], "Chief composer") },
                    { app.typeText("Ship it"); return nil },
                    { C.longPress(app.buttons["conversation.composer.send"], "send") },
                ])
            },
            Scene(group: g, id: "chief-details-header", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.tap(C.any(app, "conversation.header.name"), "header name")
            },
            Scene(group: g, id: "chief-question-bar", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.wait(C.any(app, "chief.question.bar"), "question bar")
            },
            Scene(group: g, id: "chief-question-sheet", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.tap(C.any(app, "chief.question.bar"), "question bar")
            },
            Scene(group: g, id: "chief-initial-loading", args: ["-cmux-mobile-demo", "chief-open", "-cmux-mobile-chief-slow-history"], settle: 2.2),
            Scene(group: g, id: "chief-live-bubble", args: ["-cmux-mobile-demo", "chief-open", "-cmux-mobile-chief-live"], settle: 5),
            Scene(group: g, id: "chief-outbox-unsent", args: ["-cmux-mobile-demo", "chief-open", "-cmux-mobile-chief-outbox-demo"], settle: 5),
            Scene(group: g, id: "chief-stale-try-again", args: ["-cmux-mobile-demo", "chief-open", "-cmux-mobile-chief-stale-demo"], settle: 5),
            Scene(group: g, id: "chief-settings-page", args: ["-cmux-mobile-demo", "chief-settings"], settle: 7),
            Scene(group: g, id: "chief-settings-scrolled", args: ["-cmux-mobile-demo", "chief-settings"], settle: 7) { app in
                C.scrollDown(app, times: 2)
            },
            Scene(group: g, id: "chief-colors-sheet", args: ["-cmux-mobile-demo", "chief-open"], settle: 5) { app in
                C.steps([{ C.tap(app.buttons["conversation.header.trailing"].firstMatch, "conversation menu") },
                         { C.tap(C.label(app, contains: "Chat Colors"), "Chat Colors item") }])
            },
            Scene(group: g, id: "chief-call-scope-settings", args: ["-cmux-mobile-demo", "call-scope"], settle: 6),
            Scene(group: g, id: "chief-call-live", args: ["-cmux-mobile-demo", "call-scope"], env: ["CMUX_MOBILE_CALL_DEMO": "hold"], settle: 6) { app in
                C.steps([
                    { C.tap(app.buttons["chief.settings.call"].firstMatch, "Call Chief") },
                    { _ = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch.waitForExistence(timeout: 4)
                      let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
                      if allow.exists { allow.tap() }
                      return C.wait(C.any(app, "chief.call"), "call screen", timeout: 10) },
                ])
            },
            Scene(group: g, id: "chief-call-no-key", args: ["-cmux-mobile-demo", "call-scope"], settle: 6) { app in
                C.tap(app.buttons["chief.settings.call"].firstMatch, "Call Chief")
            },
            Scene(group: g, id: "message-about-sheet", args: ["-cmux-mobile-tab", "workspaces"]) { app in
                C.steps([
                    { C.longPress(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
                    { C.tap(C.label(app, contains: "Send Message"), "Send Message item") },
                ])
            },
        ])
    }
}
