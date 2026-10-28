import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFiles
import Foundation
import Testing
import CmuxNextFilesUI

/// The file explorer's Open With submenu lists the apps that open the file, as Finder does: the
/// default app first and marked, then the others by name, then Other…. Each row is a registry row:
/// picking it runs Open With (`fileExplorerOpenWith`) with that app (Other… with none, so the
/// person picks one), with `fileExplorerFocused` though the list does not have the keyboard.
@MainActor @Suite(.serialized)
struct FileExplorerOpenWithTests {
    static let textEdit = OpenWithApp(url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let xcode = OpenWithApp(url: URL(fileURLWithPath: "/Applications/Xcode.app"), bundleID: "com.apple.dt.Xcode", name: "Xcode")
    static let bbedit = OpenWithApp(url: URL(fileURLWithPath: "/Applications/BBEdit.app"), bundleID: "com.barebones.bbedit", name: "BBEdit")

    @Test func theSubmenuListsTheDefaultAppFirstThenTheOthersThenOther() {
        let menu = FileExplorerOpenWithMenu(registry: ActionRegistry.standard())
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: Self.textEdit, apps: [Self.xcode, Self.textEdit, Self.bbedit]))
        let titles = submenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == [FileExplorerStrings.defaultApp("TextEdit"), "-", "BBEdit", "Xcode", "-", FileExplorerStrings.openWithOther])
    }

    @Test func pickingAnAppRunsOpenWithWithThatAppThroughTheRegistry() throws {
        let registry = ActionRegistry.standard()
        var runs: [ActionInvocation] = []
        registry.bind("fileExplorerOpenWith", invoke: { runs.append($0) })
        let menu = FileExplorerOpenWithMenu(registry: registry)
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: Self.textEdit, apps: [Self.xcode]))
        let xcode = try #require(submenu.items.first { $0.title == "Xcode" })
        Self.click(xcode)
        let run = try #require(runs.first)
        #expect(run["app"]?.stringValue == "/Applications/Xcode.app")
        let focused = run.keyContext?.contains(.fileExplorerFocused) == true
        #expect(focused, "the row ran without the explorer's fact")
        runs.removeAll()
        Self.click(try #require(submenu.items.last))
        #expect(runs.count == 1 && runs.first?["app"] == nil, "Other… runs Open With with no app, so the person picks one")
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
        let menu = FileExplorerOpenWithMenu(registry: ActionRegistry.standard())
        let submenu = NSMenu()
        menu.fill(submenu, with: OpenWithList(defaultApp: nil, apps: []))
        #expect(submenu.items.map(\.title) == [FileExplorerStrings.openWithOther])
    }
}
