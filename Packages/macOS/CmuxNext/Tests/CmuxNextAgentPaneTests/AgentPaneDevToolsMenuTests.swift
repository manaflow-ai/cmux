import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
import Testing

/// "make it possible to open chrome devtools in chat ui itself" (Lawrence, 2026-11-07): the agent
/// chat's right-click menu reaches the page's developer tools (Inspect Element) beside the UI
/// pointer picker. "Why is there an Inspect Element AND a Inspect UI [Element]?" (Leo, 2026-11-09):
/// the menu shows one inspect row, Point at Element… (the picker), and holding Option turns it into
/// Inspect Element. Either shows alone while the other is off.
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

    /// The rows that inspect: the picker's, the app's developer tools' and WebKit's own.
    static func inspectRows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter {
            $0.title == AgentPaneMenuStrings.pointAtElement || $0.identifier == PageDeveloperTools.itemIdentifier
                || $0.identifier?.rawValue == webKitInspect
        }
    }

    @Test func withBothOnOneRowShowsAndOptionOpensDeveloperTools() throws {
        let menu = Self.rebuilt(devTools: true, picker: true)
        let rows = Self.inspectRows(menu)
        let visible = rows.filter { !$0.isAlternate }
        #expect(visible.map(\.title) == ["Point at Element…"], "\(menu.items.map(\.title))")
        let alternate = try #require(rows.first { $0.isAlternate })
        #expect(alternate.title == "Inspect Element")
        #expect(alternate.keyEquivalentModifierMask == .option)
        #expect(alternate.keyEquivalent == visible.first?.keyEquivalent)
        // AppKit pairs an alternate with the row right before it.
        let index = menu.index(of: alternate)
        #expect(index > 0 && menu.item(at: index - 1)?.title == "Point at Element…")
    }

    @Test func withDeveloperToolsOffOnlyThePickerRowShows() {
        let menu = Self.rebuilt(devTools: false, picker: true)
        let titles = menu.items.map(\.title)
        #expect(!titles.contains("Inspect Element"), "\(titles)")
        #expect(titles.contains("Point at Element…"), "\(titles)")
        #expect(!menu.items.contains { $0.isAlternate })
    }

    @Test func withThePickerOffDeveloperToolsShowAsTheirOwnRow() {
        let menu = Self.rebuilt(devTools: true, picker: false)
        let rows = Self.inspectRows(menu)
        #expect(rows.map(\.title) == ["Inspect Element"], "\(menu.items.map(\.title))")
        #expect(rows.allSatisfy { !$0.isAlternate })
    }

    /// The class guard: in no configuration (developer tools on or off, picker on or off, the app's
    /// row or WebKit's own) does the menu show two inspect rows at once.
    @Test func noMenuShowsTwoInspectRows() {
        for devTools in [true, false] {
            for picker in [true, false] {
                for appRow in [true, false] {
                    let menu = Self.webKitMenu()
                    AgentPaneContextMenu.rebuild(menu, target: nil, devTools: devTools, scope: ThemeScope.app.fullStrength,
                                                 actions: .init(copy: { _ in }, fork: { _ in }, inspectElement: picker ? {} : nil,
                                                                inspectWithDevTools: appRow ? {} : nil))
                    let rows = Self.inspectRows(menu)
                    let visible = rows.filter { !$0.isAlternate }
                    #expect(visible.count == ((devTools || picker) ? 1 : 0),
                            "devTools \(devTools) picker \(picker) appRow \(appRow): \(menu.items.map(\.title))")
                    #expect(rows.filter(\.isAlternate).allSatisfy { $0.keyEquivalentModifierMask == .option })
                }
            }
        }
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
        #expect(row.isAlternate && row.keyEquivalentModifierMask == .option)
        #expect(menu.items.contains { $0.title == AgentPaneMenuStrings.pointAtElement })
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
