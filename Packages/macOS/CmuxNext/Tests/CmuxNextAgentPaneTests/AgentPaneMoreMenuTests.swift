import AppKit
import Testing
@testable import CmuxNextAgentPane

/// A message's More button (webviews MessageActions.tsx MessageMore) reports the message as its
/// right-click does, plus the button's box (`popUp`): the pane opens the same menu under it.
@Suite
@MainActor
struct AgentPaneMoreMenuTests {
    static func titles(_ report: [String: Any]) -> [String] {
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }))
        return menu.items.map(\.title)
    }

    @Test func aMorePressOpensTheRightClicksItemsUnderTheButton() throws {
        let rightClick: [String: Any] = ["text": "Done.", "markdown": "**Done.**", "forkSeq": 3, "links": ["https://cmux.dev"]]
        var more = rightClick
        more["popUp"] = ["left": 10, "top": 20, "right": 34, "bottom": 44]
        #expect(AgentPaneContextMenu.popUpAnchor(report: more) == CGRect(x: 10, y: 20, width: 24, height: 24))
        #expect(AgentPaneContextMenu.popUpAnchor(report: rightClick) == nil)
        #expect(Self.titles(more) == Self.titles(rightClick))
        #expect(Self.titles(more).contains(AgentPaneMenuStrings.copyAsPlainText))
    }
}
