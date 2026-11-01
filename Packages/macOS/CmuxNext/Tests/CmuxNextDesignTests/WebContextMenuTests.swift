import AppKit
@testable import CmuxNextDesign
import Testing

/// A page's right-click menu (webviews `ui/ContextMenu.tsx`) shows as a standard macOS menu
/// (Lawrence 2026-10-23): every row a plain `NSMenuItem` with the page's label, state and SF Symbol
/// icon, separators as AppKit's, and a chosen row answers its id.
@MainActor @Suite struct WebContextMenuTests {
    private static let params: [String: Any] = [
        "items": [
            ["id": "separator:lead", "label": "", "separator": true],
            ["id": "rename", "label": "Rename", "symbol": "pencil"],
            ["id": "copy", "label": "Copy", "disabled": true],
            ["id": "separator:close", "label": "", "separator": true],
            ["id": "separator:again", "label": "", "separator": true],
            ["id": "close", "label": "Close", "checked": true],
            ["id": "separator:trail", "label": "", "separator": true],
        ],
        "point": ["x": 40, "y": 60.5],
    ]

    @Test func readsTheRowsAndThePointer() throws {
        let menu = try #require(WebContextMenu(Self.params))
        #expect(menu.point == CGPoint(x: 40, y: 60.5))
        #expect(menu.rows.filter { !$0.separator }.map(\.id) == ["rename", "copy", "close"])
        #expect(WebContextMenu(["items": [["id": "a", "label": "", "separator": true]], "point": ["x": 0, "y": 0]])?.rows == nil,
                "a menu with nothing to choose shows nothing")
        #expect(WebContextMenu(["items": [[String: Any]](), "point": ["x": 0, "y": 0]])?.rows == nil)
    }

    @Test func everyRowIsANativeMenuItem() throws {
        _ = NSApplication.shared
        let menu = try #require(WebContextMenu(Self.params)).menu { _ in }
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Rename", "Copy", "-", "Close"],
                "no separator first, last or twice")
        for item in menu.items {
            #expect(item.view == nil, "\(item.title) is custom-drawn")
            #expect(item.attributedTitle == nil, "\(item.title) has a custom font or color")
        }
        #expect(menu.items[0].image != nil, "Rename has its SF Symbol")
        #expect(menu.items[1].image == nil && !menu.items[1].isEnabled)
        #expect(menu.items[3].state == .on)
        #expect(menu.appearance == nil, "the menu takes the clicked view's system look")
    }

    @Test func aChosenRowAnswersItsID() throws {
        _ = NSApplication.shared
        var chosen: [String] = []
        let menu = try #require(WebContextMenu(Self.params)).menu { chosen.append($0) }
        menu.performActionForItem(at: 3)
        #expect(chosen == ["close"])
    }
}
