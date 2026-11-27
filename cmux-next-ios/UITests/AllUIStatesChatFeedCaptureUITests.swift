import XCTest

/// All-UI-states capture, part 5: agent chats, the Feed, and notifications
/// outside the app. See `UIStateCapture.swift`.
final class AllUIStatesChatFeedCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let idleChat = ["-cmux-mobile-demo", "disclosure-chat"]
    private static let feed = ["-cmux-mobile-tab", "feed"]

    @MainActor
    private static func more(_ app: XCUIApplication) -> String? {
        tap(app.navigationBars.buttons["More"].firstMatch, "chat More", timeout: 30)
    }

    @MainActor
    private static func moreItem(_ app: XCUIApplication, _ item: String) -> String? {
        steps([{ more(app) }, { tap(label(app, contains: item), item) }])
    }

    /// The agent chat shows its composer collapsed ("Reply to …") until tapped.
    @MainActor
    private static func openComposer(_ app: XCUIApplication) -> String? {
        steps([
            { wait(app.navigationBars.buttons["More"].firstMatch, "chat", timeout: 30) },
            { let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
              if bar.waitForExistence(timeout: 10) { _ = tap(bar, "composer bar") }
              return showKeyboard(app, field: app.textViews["chat.composer.field"], "chat composer") },
        ])
    }

    @MainActor
    private static func send(_ app: XCUIApplication, _ text: String) -> String? {
        steps([
            { openComposer(app) },
            { app.typeText(text); return nil },
            { tap(app.buttons["Send"].firstMatch, "Send") },
        ])
    }

    @MainActor
    func testAgentChat() {
        let g = "11 Agent chat"
        capture([
            Scene(group: g, id: "pending-question", args: ["-cmux-mobile-demo", "kbd-chat"], settle: 6),
            Scene(group: g, id: "idle-with-history", args: Self.idleChat, settle: 6),
            Scene(group: g, id: "history-scrolled-up", args: Self.idleChat, settle: 6) { app in
                for _ in 0..<4 {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
                }
                return nil
            },
            Scene(group: g, id: "keyboard-up-draft", args: Self.idleChat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { app.typeText("Run the tests"); return nil }])
            },
            Scene(group: g, id: "slash-suggestions", args: Self.idleChat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { app.typeText("/"); return nil }])
            },
            Scene(group: g, id: "mention-suggestions", args: Self.idleChat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { app.typeText("@"); return nil }])
            },
            Scene(group: g, id: "running-turn-stop", args: Self.idleChat, settle: 6) { app in
                C.steps([{ Self.send(app, "Summarize the transport layer") }, { C.wait(app.buttons["Stop"].firstMatch, "Stop button", timeout: 10) }])
            },
            Scene(group: g, id: "turn-finished", args: Self.idleChat, settle: 6) { app in
                C.steps([{ Self.send(app, "Summarize the transport layer") }, { C.pause(14); return nil }])
            },
            Scene(group: g, id: "rich-first-turn", args: ["-cmux-mobile-demo", "kbd-chat-empty"], settle: 6) { app in
                C.steps([{ Self.send(app, "Plan the release") }, { C.pause(10); return nil }])
            },
            Scene(group: g, id: "empty-chat-home", args: ["-cmux-mobile-demo", "kbd-chat-empty"], settle: 6),
            Scene(group: g, id: "offline-queued", args: ["-cmux-mobile-demo", "offline-send"], settle: 8),
            Scene(group: g, id: "offline-queued-menu", args: ["-cmux-mobile-demo", "offline-send"], settle: 8) { app in
                C.longPress(C.any(app, "chat.queued"), "queued chip")
            },
            Scene(group: g, id: "more-menu", args: Self.idleChat, settle: 6) { app in Self.more(app) },
            Scene(group: g, id: "files-and-artifacts", args: Self.idleChat, settle: 6) { app in Self.moreItem(app, "Files and Artifacts") },
            Scene(group: g, id: "agent-edits-review", args: Self.idleChat, settle: 6) { app in
                C.tap(app.buttons["Review"].firstMatch, "Review (files changed)")
            },
            Scene(group: g, id: "answer-row-menu", args: Self.idleChat, settle: 6) { app in
                let header = app.navigationBars.buttons["More"].firstMatch
                guard header.waitForExistence(timeout: 30) else { return "no chat" }
                let rowMore = app.buttons.matching(NSPredicate(format: "label == %@", "More")).allElementsBoundByIndex
                    .filter { $0.frame.minY > header.frame.maxY + 20 }.max { $0.frame.minY < $1.frame.minY }
                guard let rowMore else { return "no answer … button" }
                return C.tap(rowMore, "answer … button")
            },
            Scene(group: g, id: "share-transcript", args: Self.idleChat, settle: 6) { app in Self.moreItem(app, "Share Transcript") },
            Scene(group: g, id: "answer-context-menu", args: Self.idleChat, settle: 6) { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).press(forDuration: 1.2)
                return nil
            },
            Scene(group: g, id: "select-text", args: Self.idleChat, settle: 6) { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).press(forDuration: 1.2)
                return C.tap(app.buttons["Select Text"].firstMatch, "Select Text")
            },
            Scene(group: g, id: "voice-mode", args: ["-cmux-mobile-demo", "voice-chat"],
                  env: ["CMUX_MOBILE_VOICE_MODE_DEMO": "1", "CMUX_MOBILE_VOICE_MODE_DEMO_PROMPT": "what changed today"], settle: 6) { app in
                C.steps([{ C.tap(app.buttons["agentChat.composer.voice"], "voice button") }, { C.wait(app.otherElements["voiceMode.bar"].firstMatch, "voice bar", timeout: 10) }])
            },
            Scene(group: g, id: "parity-subagents", args: ["-CmuxMobileDemo", "acp-parity", "-CmuxMobileDemoPhases", "subagents"], settle: 0,
                  frames: [("parity-subagents-list", 8), ("parity-subagent-open", 13)]),
            Scene(group: g, id: "parity-checkpoints", args: ["-CmuxMobileDemo", "acp-parity", "-CmuxMobileDemoPhases", "checkpoints"], settle: 0,
                  frames: [("parity-checkpoints-list", 8), ("parity-checkpoint-restore", 13)]),
            Scene(group: g, id: "parity-handoff", args: ["-CmuxMobileDemo", "acp-parity", "-CmuxMobileDemoPhases", "handoff"], settle: 0,
                  frames: [("parity-handoff", 8), ("parity-handoff-started", 13)]),
            Scene(group: g, id: "chat-feed-tour", args: ["-CmuxMobileDemo", "chat-feed"], settle: 0,
                  frames: [("tour-feed", 4), ("tour-show-more", 9), ("tour-inline-answer", 14), ("tour-chat-streaming", 22),
                           ("tour-permission-in-chat", 28), ("tour-question-in-chat", 34), ("tour-diff", 42), ("tour-changes", 52)]),
            Scene(group: g, id: "pending-permission-codex", args: ["-cmux-mobile-tab", "workspaces"]) { app in
                C.steps([
                    { C.tap(app.buttons["workspace.row.ws-ghostty"], "ws-ghostty row") },
                    { C.pause(1.5); return C.tap(app.buttons["Tabs"].firstMatch, "Tabs") },
                    { C.tap(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'codex' AND label ENDSWITH ', tab'")).firstMatch, "Codex card") },
                ])
            },
            Scene(group: g, id: "incoming-agent-cards", args: Self.idleChat, settle: 6) { app in
                let digest = app.staticTexts["3 messages"].firstMatch
                for _ in 0..<12 where !digest.isHittable {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
                }
                return digest.isHittable ? nil : "no digest card"
            },
        ])
    }

    @MainActor
    func testFeed() {
        let g = "12 Feed"
        capture([
            Scene(group: g, id: "feed", args: Self.feed),
            Scene(group: g, id: "feed-scrolled", args: Self.feed) { app in C.scrollDown(app, times: 2) },
            Scene(group: g, id: "feed-bottom", args: Self.feed) { app in C.scrollDown(app, times: 6) },
            Scene(group: g, id: "chip-needs-you", args: Self.feed) { app in C.tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Needs you'")).firstMatch, "Needs you chip") },
            Scene(group: g, id: "chip-finished", args: Self.feed) { app in C.tap(app.buttons["Finished"].firstMatch, "Finished chip") },
            Scene(group: g, id: "chip-errors", args: Self.feed) { app in C.tap(app.buttons["Errors"].firstMatch, "Errors chip") },
            Scene(group: g, id: "filter-menu", args: Self.feed) { app in C.tap(app.buttons["Filter"].firstMatch, "Filter menu") },
            Scene(group: g, id: "show-more-expanded", args: Self.feed) { app in
                let row = app.tables["feed.list"].cells["feed.row.f-long"]
                for _ in 0..<6 where !row.isHittable { _ = C.scrollDown(app) }
                return C.tap(row.buttons.matching(NSPredicate(format: "identifier == 'feed.row.showMore' OR label == 'Show more'")).firstMatch, "Show more")
            },
            Scene(group: g, id: "swipe-permission", args: Self.feed) { app in
                C.swipeLeft(app.tables["feed.list"].cells["feed.row.f-permission"], "permission row")
            },
            Scene(group: g, id: "swipe-read-done", args: Self.feed) { app in
                C.swipeLeft(app.tables["feed.list"].cells["feed.row.f-pricing"], "pricing row")
            },
            Scene(group: g, id: "marked-done-undo", args: Self.feed) { app in
                C.steps([{ C.swipeLeft(app.tables["feed.list"].cells["feed.row.f-pricing"], "pricing row") }, { C.tap(app.tables["feed.list"].buttons["Done"], "Done action") }])
            },
            Scene(group: g, id: "permission-sending", args: Self.feed + ["-cmuxMobile.dev.slowApproval", "YES"]) { app in
                C.steps([{ C.swipeLeft(app.tables["feed.list"].cells["feed.row.f-permission"], "permission row") }, { C.tap(app.tables["feed.list"].buttons["Allow"], "Allow action") }])
            },
            Scene(group: g, id: "row-context-menu", args: Self.feed) { app in C.longPress(app.tables["feed.list"].cells["feed.row.f-pricing"], "pricing row") },
            Scene(group: g, id: "open-finished-chat", args: Self.feed) { app in
                let row = app.tables["feed.list"].cells["feed.row.f-finished"]
                for _ in 0..<6 where !row.isHittable { _ = C.scrollDown(app) }
                return C.tap(row, "finished row")
            },
            Scene(group: g, id: "refresh-error-retry", args: ["-cmux-mobile-demo", "retry-feed"], settle: 4),
            Scene(group: g, id: "new-events-pill", args: Self.feed,
                  env: ["CMUX_MOBILE_FEED_STRESS": "300", "CMUX_MOBILE_FEED_STRESS_LIVE": "3"], settle: 4) { app in
                C.steps([{ C.tap(app.buttons["All"].firstMatch, "All chip") }, { C.scrollDown(app, times: 3) }, { C.wait(app.buttons["feed.newPill"], "new events pill", timeout: 15) }])
            },
            Scene(group: g, id: "stress-300", args: Self.feed, env: ["CMUX_MOBILE_FEED_STRESS": "300"], settle: 4),
        ])
    }

    /// One synthetic push of each kind, as the person sees it in Notification
    /// Center and in its long look (the content extension).
    @MainActor
    func testNotifications() {
        let g = "14 Notifications outside the app"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for kind in ["permission", "question", "completed", "failed", "chief", "terminal"] {
            for look in Look.allCases {
                XCUIDevice.shared.appearance = look.device
                let app = XCUIApplication()
                app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                app.launchEnvironment["CMUX_MOBILE_DEV_SERVICE_PUSH"] = Self.push(kind)
                app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
                app.launch()
                let allow = springboard.alerts.buttons["Allow"].firstMatch
                if allow.waitForExistence(timeout: 8) {
                    if kind == "permission" && look == .light { attachShot(group: g, id: "system-permission-alert", look: look, miss: nil) }
                    allow.tap()
                }
                C.pause(3)
                XCUIDevice.shared.press(.home)
                C.pause(1.5)
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
                    .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
                C.pause(2)
                let platter = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
                let found = platter.waitForExistence(timeout: 6)
                attachShot(group: g, id: "\(kind)-notification-center", look: look, miss: found ? nil : "no notification platter")
                if found {
                    platter.press(forDuration: 1.2)
                    C.pause(2.5)
                    attachShot(group: g, id: "\(kind)-long-look", look: look, miss: nil)
                }
                XCUIDevice.shared.press(.home)
                C.pause(1)
                app.terminate()
            }
        }
    }

    private static func push(_ kind: String) -> String {
        var payload: [String: Any] = [
            "v": 2, "mac": "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "macName": "Mac mini", "kind": kind,
            "eventId": "capture-\(kind)", "agent": kind == "chief" ? "Chief" : "Claude Code", "workspace": "cmux",
            "postedAt": Int(Date().timeIntervalSince1970),
        ]
        var category = "CMUX_MOBILE_\(kind.uppercased())"
        switch kind {
        case "permission":
            payload["sessionId"] = "capture-session"; payload["permissionId"] = "capture-perm"
            payload["title"] = "rm -rf build && swift build -c release"
            payload["options"] = [["id": "allow-once", "label": "Allow once", "kind": "allow_once"],
                                  ["id": "allow-always", "label": "Always allow", "kind": "allow_always"],
                                  ["id": "deny", "label": "Deny", "kind": "reject_once"]]
        case "question":
            payload["sessionId"] = "capture-session"
            payload["questions"] = [["question": "Which transport should the release default to?", "header": "Transport",
                                     "multiSelect": false, "allowsOther": true,
                                     "options": [["label": "WireGuard"], ["label": "WebRTC"]]]]
            category = "CMUX_MOBILE_QUESTION"
        case "completed":
            payload["sessionId"] = "capture-session"; payload["title"] = "Finished: release notes drafted"
            payload["body"] = "Drafted the 1.4 notes and opened a PR."
        case "failed":
            payload["sessionId"] = "capture-session"; payload["title"] = "Failed: swift build"
            payload["body"] = "error: cannot find 'LinkMachine' in scope"
        case "chief":
            payload["conversationId"] = "home"; payload["title"] = "Chief"
            payload["body"] = "The nightly is green again. Two PRs are ready for you to try."
        default:
            payload["notificationId"] = "capture-terminal"; payload["title"] = "zsh"; payload["body"] = "Build finished in 4m 12s"
        }
        let body: [String: Any] = ["aps": ["category": category, "mutable-content": 1], "cmuxMobile": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
