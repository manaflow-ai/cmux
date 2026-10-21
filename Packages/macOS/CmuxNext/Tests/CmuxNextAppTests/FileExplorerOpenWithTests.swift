import AppKit
@testable import CmuxNextApp
import CmuxNextFiles
import Foundation
import Testing

/// The file explorer's Open With submenu lists the apps that open the file, as Finder does: the
/// default app first and marked, then the others by name, then Other…. Picking a row runs Open
/// With (`fileExplorerOpenWith`) with that app.
@MainActor @Suite(.serialized)
struct FileExplorerOpenWithTests {
    static let textEdit = OpenWithApp(url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let xcode = OpenWithApp(url: URL(fileURLWithPath: "/Applications/Xcode.app"), bundleID: "com.apple.dt.Xcode", name: "Xcode")
    static let bbedit = OpenWithApp(url: URL(fileURLWithPath: "/Applications/BBEdit.app"), bundleID: "com.barebones.bbedit", name: "BBEdit")

    @Test func theSubmenuListsTheDefaultAppFirstThenTheOthersThenOther() {
        let menu = FileExplorerOpenWithMenu(open: { _ in }, chooseOther: {})
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: Self.textEdit, apps: [Self.xcode, Self.textEdit, Self.bbedit]))
        let titles = submenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == [FileExplorerStrings.defaultApp("TextEdit"), "-", "BBEdit", "Xcode", "-", FileExplorerStrings.openWithOther])
    }

    @Test func pickingAnAppOpensWithThatApp() throws {
        var opened: [String] = []
        var chose = 0
        let menu = FileExplorerOpenWithMenu(open: { opened.append($0) }, chooseOther: { chose += 1 })
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: Self.textEdit, apps: [Self.xcode]))
        let xcode = try #require(submenu.items.firstIndex { $0.title == "Xcode" })
        Self.click(submenu.items[xcode])
        #expect(opened == ["/Applications/Xcode.app"])
        Self.click(try #require(submenu.items.last))
        #expect(chose == 1)
    }

    /// What a click on a menu row does: its action, sent to its target.
    static func click(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else {
            Issue.record("the row \(item.title) runs nothing")
            return
        }
        target.perform(action, with: item)
    }

    @Test func withNoAppForTheTypeOnlyOtherShows() {
        let menu = FileExplorerOpenWithMenu(open: { _ in }, chooseOther: {})
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: nil, apps: []))
        #expect(submenu.items.map(\.title) == [FileExplorerStrings.openWithOther])
    }
}
