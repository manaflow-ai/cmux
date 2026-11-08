import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
import Testing

/// "make it possible to open chrome devtools in chat ui itself" (Lawrence, 2026-11-07): the agent
/// chat's right-click menu offers Inspect Element, which opens the page's developer tools, beside
/// the Labs UI pointer picker. The picker once took the "Inspect Element" title and removed the
/// developer tools row, so with the picker on (its default) no menu opened them.
@Suite(.serialized)
@MainActor
struct AgentPaneDevToolsMenuTests {
    static let webKitInspect = "WKMenuItemIdentifierInspectElement"

    /// WebKit's menu with its Copy and Inspect Element items, as WebKit gives it to the pane.
    static func webKitMenu() -> NSMenu {
        _ = NSApplication.shared
        let menu = NSMenu()
        for (identifier, title) in [("WKMenuItemIdentifierCopy", "Copy"), (webKitInspect, "Inspect Element")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
        }
        return menu
    }

    static func rebuilt(devTools: Bool, picker: Bool) -> NSMenu {
        let menu = webKitMenu()
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: devTools, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: { _ in }, fork: { _ in }, inspectElement: picker ? {} : nil))
        return menu
    }

    @Test func withThePickerOnTheMenuStillOpensDeveloperTools() {
        let menu = Self.rebuilt(devTools: true, picker: true)
        let titles = menu.items.map(\.title)
        #expect(titles.filter { $0 == "Inspect Element" }.count == 1, "\(titles)")
        #expect(titles.contains("Inspect UI Element"), "the picker row lost its own name: \(titles)")
    }

    @Test func withDeveloperToolsOffOnlyThePickerRowShows() {
        let menu = Self.rebuilt(devTools: false, picker: true)
        let titles = menu.items.map(\.title)
        #expect(!titles.contains("Inspect Element"), "\(titles)")
        #expect(titles.contains("Inspect UI Element"), "\(titles)")
    }

    /// With the app's developer tools (``PageDeveloperTools``), the row is the app's own, in either
    /// engine (a Chromium chat's menu has no WebKit item): one Inspect Element that opens them.
    @Test func theDeveloperToolsRowRunsTheAppsInspector() throws {
        let menu = Self.webKitMenu()
        var ran = 0
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: true, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: { _ in }, fork: { _ in }, inspectElement: {}, inspectWithDevTools: { ran += 1 }))
        #expect(!menu.items.contains { $0.identifier?.rawValue == Self.webKitInspect })
        let rows = menu.items.filter { $0.identifier == PageDeveloperTools.itemIdentifier }
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == PageDeveloperTools.title)
        #expect(menu.items.contains { $0.title == AgentPaneMenuStrings.inspectUIElement })
        _ = (row.target as? NSObject)?.perform(row.action)
        #expect(ran == 1)
    }

    @Test func aChromiumChatMenuWithoutWebKitItemsStillOffersIt() {
        _ = NSApplication.shared
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: nil, devTools: true, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: { _ in }, fork: { _ in }, inspectWithDevTools: {}))
        #expect(menu.items.map(\.title).contains(PageDeveloperTools.title))
    }
}
