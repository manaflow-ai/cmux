import AppKit
@testable import CmuxNextActions
import Testing

/// The bookmark manager's more (⋮) button is the app's one ``OverflowButton`` (Leo 2026-10-20), so its
/// rows are registered actions (check-menu-actions): Add Bookmark and New Folder add to the shown
/// folder, then import and export, each on the page's profile, through the same handler the palette,
/// the menu bar and `cmux bookmark …` run.
@MainActor
struct BookmarkManagerMenuTests {
    private let arguments: [String: ActionValue] = ["folder": .string("folder_7"), "profile": .string("work")]

    @Test func theMenuListsTheRegisteredBookmarkActions() {
        let rows = ContextMenuCatalog.shared.entries(for: .bookmarkManager).map { entry -> String in
            if case .action(let id) = entry { return id.rawValue }
            return entry == .separator ? "—" : "?"
        }
        #expect(rows == ["bookmark.add", "bookmark.newFolder", "—", "bookmark.importFromBrowser", "bookmark.import", "bookmark.export"])
    }

    @Test func eachRowRunsItsActionOnTheShownFolderAndProfile() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var runs: [(id: ActionID, invocation: ActionInvocation)] = []
        var asked: [(id: ActionID, invocation: ActionInvocation)] = []
        for id: ActionID in ["bookmark.add", "bookmark.newFolder", "bookmark.importFromBrowser", "bookmark.import", "bookmark.export"] {
            registry.bind(id, invoke: { runs.append((id, $0)) })
        }
        registry.argumentCollector = { asked.append(($0, $1)) }
        let menu = registry.makeContextMenu(for: .bookmarkManager, arguments: arguments)
        for item in menu.items where !item.isSeparatorItem {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }

        // Add Bookmark and New Folder ask the palette for the URL and the name, keeping the folder and profile.
        #expect(asked.map(\.id) == ["bookmark.add", "bookmark.newFolder"])
        #expect(runs.map(\.id) == ["bookmark.importFromBrowser", "bookmark.import", "bookmark.export"])
        for run in asked + runs {
            #expect(run.invocation["profile"] == .string("work"), "\(run.id) runs on the page's profile")
            #expect(run.invocation.origin == .user)
        }
        for run in asked { #expect(run.invocation["folder"] == .string("folder_7"), "\(run.id) adds to the shown folder") }
    }
}
