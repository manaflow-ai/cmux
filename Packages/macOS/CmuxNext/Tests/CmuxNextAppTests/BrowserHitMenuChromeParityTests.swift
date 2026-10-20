import CmuxNextActions
import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

/// Every Chromium row the page menu drops for a right-click is replaced by
/// a cmux row that the menu really shows for it: the row's action is in
/// that context's catalog menu (so the palette, CLI and MCP run the same
/// action) and its section is generated for the right-click.
@Suite struct BrowserHitMenuChromeParityTests {
    nonisolated static let link = URL(string: "https://example.com/a")!
    nonisolated static let image = URL(string: "https://example.com/a.png")!

    nonisolated static let targets: [BrowserContextMenuTarget] = [
        BrowserContextMenuTarget(linkURL: link, linkText: "A"),
        BrowserContextMenuTarget(linkURL: link),
        BrowserContextMenuTarget(sourceURL: image, imageURL: image),
        BrowserContextMenuTarget(linkURL: link, linkText: "A", sourceURL: image, imageURL: image, selection: "hi"),
        BrowserContextMenuTarget(selection: "hello"),
        BrowserContextMenuTarget(selection: "teh", isEditable: true),
        BrowserContextMenuTarget(selection: " \n"),
        BrowserContextMenuTarget(),
    ]

    @Test(arguments: targets.indices) func everyDroppedChromeRowHasItsCmuxRow(_ index: Int) {
        let target = Self.targets[index]
        let sections = BrowserHitMenu.sections(for: target)
        var shown: Set<String> = []
        for section in sections {
            shown.formUnion(Self.actions(in: ContextMenuCatalog.shared.entries(for: section.context, removing: section.hidden)))
        }
        for (command, action) in BrowserContextMenuItem.replacedChromiumRows(for: target) {
            #expect(shown.contains(action), "Chromium row \(command) is dropped but \(action) is not shown")
        }
    }

    static func actions(in entries: [ContextMenuEntry]) -> Set<String> {
        var result: Set<String> = []
        for entry in entries {
            switch entry {
            case .action(let id), .choices(let id): result.insert(id.rawValue)
            case .submenu(let id, let children): result.insert(id.rawValue); result.formUnion(actions(in: children))
            case .folder(_, let children): result.formUnion(actions(in: children))
            default: break
            }
        }
        return result
    }

    /// Chrome names Copy Link "Copy Email Address" on a `mailto:` link.
    @Test func mailtoLinksCopyAnEmailAddress() {
        let mail = BrowserContextMenuTarget(linkURL: URL(string: "mailto:a@example.com")!)
        #expect(BrowserHitMenu.title(of: "browser.link.copy", for: mail, searchEngine: "Google") == BrowserHitStrings.copyEmailAddress)
        #expect(BrowserHitMenu.title(of: "browser.link.copy", for: BrowserContextMenuTarget(linkURL: Self.link), searchEngine: "Google") == nil)
        let selection = BrowserContextMenuTarget(selection: "hello")
        #expect(BrowserHitMenu.title(of: "browser.selection.search", for: selection, searchEngine: "Google") == "Search Google for “hello”")
    }
}
