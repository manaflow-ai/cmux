import XCTest

/// The agent chat composer's pickers, as the Mac's: a model button whose menu nests the models
/// under the harness (Claude > the model), then Mode and Effort as their own buttons. One shot
/// per state in light and dark (see `UIStateCapture.swift`), including a large text size where
/// the chips scroll sideways.
final class AgentComposerPickersCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let chat = ["-cmux-mobile-demo", "disclosure-chat"]
    private static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]

    /// The composer opens out of its collapsed "Reply to …" capsule; the chips show in the open one.
    @MainActor
    private static func openComposer(_ app: XCUIApplication) -> String? {
        C.steps([
            { C.wait(app.navigationBars.buttons["More"].firstMatch, "chat", timeout: 30) },
            { let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
              if bar.waitForExistence(timeout: 10) { _ = C.tap(bar, "composer bar") }
              return C.wait(app.buttons["agentChat.composer.model"].firstMatch, "model button", timeout: 10) },
        ])
    }

    @MainActor
    private static func chip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons["agentChat.composer.\(id)"].firstMatch
    }

    @MainActor
    private static func pick(_ app: XCUIApplication, _ chipID: String, _ item: String) -> String? {
        C.steps([
            { C.tap(chip(app, chipID), "\(chipID) button") },
            { C.tap(app.buttons[item].firstMatch, item) },
            { C.pause(0.8); return nil },
        ])
    }

    @MainActor
    func testComposerPickers() {
        let g = "Composer pickers"
        capture([
            Scene(group: g, id: "rest", args: Self.chat, settle: 6) { app in Self.openComposer(app) },
            Scene(group: g, id: "model-menu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(Self.chip(app, "model"), "model button") }])
            },
            Scene(group: g, id: "model-menu-claude-submenu", args: Self.chat, settle: 6) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { C.tap(Self.chip(app, "model"), "model button") },
                    { C.tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude'")).firstMatch, "Claude submenu") },
                ])
            },
            Scene(group: g, id: "mode-menu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(Self.chip(app, "mode"), "mode button") }])
            },
            Scene(group: g, id: "effort-menu", args: Self.chat, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(Self.chip(app, "effort"), "effort button") }])
            },
            Scene(group: g, id: "after-picks-sonnet-plan-high", args: Self.chat, settle: 6) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { C.tap(Self.chip(app, "model"), "model button") },
                    { C.tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude'")).firstMatch, "Claude submenu") },
                    { C.tap(app.buttons["Sonnet 5.5"].firstMatch, "Sonnet 5.5") },
                    { C.pause(0.8); return nil },
                    { Self.pick(app, "mode", "Plan") },
                    { Self.pick(app, "effort", "High") },
                ])
            },
            Scene(group: g, id: "large-text-rest", args: Self.chat + Self.largeText, settle: 6) { app in Self.openComposer(app) },
            Scene(group: g, id: "large-text-chips-scrolled", args: Self.chat + Self.largeText, settle: 6) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { let model = Self.chip(app, "model")
                      model.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                          .press(forDuration: 0.05, thenDragTo: model.coordinate(withNormalizedOffset: CGVector(dx: -1.5, dy: 0.5)))
                      return nil },
                ])
            },
            Scene(group: g, id: "large-text-effort-menu", args: Self.chat + Self.largeText, settle: 6) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(Self.chip(app, "effort"), "effort button") }])
            },
        ])
    }
}
