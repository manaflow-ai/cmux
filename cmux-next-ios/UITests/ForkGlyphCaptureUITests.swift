import XCTest

/// The fork rows' glyph on the phone, for a change's before and after: an agent tab's page menu
/// and its card's context menu, where Fork Conversation… shows the pack's agent.fork split arrow
/// (`CmuxSymbol.fork`). Run with `cmux-next-ios-sim.sh test ui=ForkGlyphCaptureUITests`.
final class ForkGlyphCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let list = ["-cmux-mobile-tab", "workspaces"]

    @MainActor
    func testForkRows() {
        let g = "Fork glyph"
        let card = { (app: XCUIApplication) in
            app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'")).firstMatch
        }
        let grid = { (app: XCUIApplication) -> String? in
            C.steps([{ C.tap(app.buttons["workspace.row.ws-cmux"], "ws-cmux row") },
                     { C.pause(1.5); return C.tap(app.buttons["Tabs"].firstMatch, "Tabs button") },
                     { C.pause(1.5); return nil }])
        }
        capture([
            // The Claude chat's page, then its page menu (Fork Conversation…, Archive, …).
            Scene(group: g, id: "agent-page-menu", args: Self.list) { app in
                C.steps([{ grid(app) }, { C.tap(card(app), "the Claude chat card") },
                         { C.pause(2.5); return C.tap(app.buttons["Page Menu"].firstMatch, "Page Menu") },
                         { C.pause(1.5); return nil }])
            },
            // The Claude chat card's context menu in the tabs grid.
            Scene(group: g, id: "agent-card-menu", args: Self.list) { app in
                C.steps([{ grid(app) }, { C.longPress(card(app), "the Claude chat card") }, { C.pause(1.5); return nil }])
            },
        ])
    }
}
