import XCTest

/// The agent chat composer's picker: one button whose menu holds three nested submenus, the
/// harness with its models (Claude > the model, as the Mac nests them), Mode and Effort. One shot
/// per state in light and dark (see `UIStateCapture.swift`), including a large text size.
final class AgentComposerPickersCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let chat = ["-cmux-mobile-demo", "disclosure-chat"]
    private static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]

    /// The composer opens out of its collapsed "Reply to …" capsule; the picker shows in the open one.
    @MainActor
    private static func openComposer(_ app: XCUIApplication) -> String? {
        C.steps([
            { C.wait(app.navigationBars.buttons["More"].firstMatch, "chat", timeout: 30) },
            { let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
              if bar.waitForExistence(timeout: 10) { _ = C.tap(bar, "composer bar") }
              return C.wait(app.buttons["agentChat.composer.model"].firstMatch, "picker button", timeout: 10) },
        ])
    }

    @MainActor
    private static func row(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Opens the picker, then the submenu whose row starts with `submenu`.
    @MainActor
    private static func openSubmenu(_ app: XCUIApplication, _ submenu: String) -> String? {
        C.steps([
            { C.tap(app.buttons["agentChat.composer.model"].firstMatch, "picker button") },
            { C.tap(row(app, submenu), "\(submenu) submenu") },
        ])
    }

    @MainActor
    private static func pick(_ app: XCUIApplication, _ submenu: String, _ item: String) -> String? {
        C.steps([
            { openSubmenu(app, submenu) },
            { C.tap(app.buttons[item].firstMatch, item) },
            { C.pause(0.8); return nil },
        ])
    }

    @MainActor
    func testComposerPickers() {
        let g = "Composer pickers"
        capture([
            Scene(group: g, id: "rest", args: Self.chat, settle: 6) { app in Self.openComposer(app) },
            Scene(group: g, id: "menu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(app.buttons["agentChat.composer.model"].firstMatch, "picker button") }])
            },
            Scene(group: g, id: "claude-submenu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openSubmenu(app, "Claude") }])
            },
            Scene(group: g, id: "mode-submenu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openSubmenu(app, "Mode") }])
            },
            Scene(group: g, id: "effort-submenu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openSubmenu(app, "Effort") }])
            },
            Scene(group: g, id: "after-picks-sonnet-plan-high", args: Self.chat, settle: 6) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { Self.pick(app, "Claude", "Sonnet 5.5") },
                    { Self.pick(app, "Mode", "Plan") },
                    { Self.pick(app, "Effort", "High") },
                ])
            },
            Scene(group: g, id: "after-picks-menu", args: Self.chat, settle: 6) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { Self.pick(app, "Claude", "Sonnet 5.5") },
                    { Self.pick(app, "Mode", "Plan") },
                    { Self.pick(app, "Effort", "High") },
                    { C.tap(app.buttons["agentChat.composer.model"].firstMatch, "picker button") },
                ])
            },
            Scene(group: g, id: "large-text-rest", args: Self.chat + Self.largeText, settle: 6) { app in Self.openComposer(app) },
            Scene(group: g, id: "large-text-menu", args: Self.chat + Self.largeText, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(app.buttons["agentChat.composer.model"].firstMatch, "picker button") }])
            },
            Scene(group: g, id: "large-text-effort-submenu", args: Self.chat + Self.largeText, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openSubmenu(app, "Effort") }])
            },
        ])
    }
}
