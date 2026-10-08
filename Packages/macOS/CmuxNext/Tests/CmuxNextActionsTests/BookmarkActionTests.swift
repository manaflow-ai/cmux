import AppKit
import CmuxNextActions
import Testing

/// Bookmark actions (plans/cmux-next/bookmarks.md section 3): every verb has
/// a `bookmark …` CLI name, the bar toggle owns Cmd-Shift-B, Cmd-D
/// stays Split Right, and the bar's menus reference only these verbs.
@Suite struct BookmarkActionTests {
    let catalog = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })

    static let ids: [ActionID] = [
        "bookmark.addPage", "bookmark.addAllTabs", "bookmark.add", "bookmark.newFolder", "bookmark.open",
        "bookmark.openInNewTab", "bookmark.openInBackgroundTab", "bookmark.openAll", "bookmark.edit", "bookmark.move",
        "bookmark.remove", "bookmark.toggleBar", "bookmark.manager", "bookmark.import", "bookmark.export",
    ]

    @Test func everyBookmarkActionHasABookmarkCLIVerb() throws {
        for id in Self.ids {
            let descriptor = try #require(catalog[id], "\(id)")
            #expect(descriptor.cliName.hasPrefix("bookmark "), "\(id): \(descriptor.cliName)")
        }
    }

    @Test func chromeBarChordIsTheToggleAndCmdDStaysSplit() throws {
        let toggle = try #require(catalog["bookmark.toggleBar"])
        #expect(toggle.defaultShortcut == Shortcut("b", modifiers: [.command, .shift]))
        let owners = ActionCatalog.all.filter { $0.defaultShortcut == Shortcut("b", modifiers: [.command, .shift]) }.map(\.id)
        #expect(owners == ["bookmark.toggleBar"])
        #expect(try #require(catalog["bookmark.addPage"]).defaultShortcut == nil)
        #expect(try #require(catalog["splitRight"]).defaultShortcut == Shortcut("d", modifiers: [.command]))
    }

    @Test func barMenusReferenceKnownActions() {
        for context in [ActionMenuContext.bookmark, .bookmarksBar] {
            let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
            #expect(!ids.isEmpty)
            for id in ids { #expect(catalog[id] != nil, "\(context): \(id)") }
        }
        #expect(ActionMenuContext.bookmark.targetKind == .bookmark)
        #expect(ActionTargetRef(parsing: "bookmark:bm_0123456789abcdef0123456789abcdef")?.kind == .bookmark)
    }

    /// cx-k9go: a bookmark's menu copies its address (Chrome's Copy), the
    /// palette offers it with a bookmark query, and a folder's menu leaves
    /// it out.
    @MainActor @Test func aBookmarkMenuCopiesItsLinkAndAFolderMenuDoesNot() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .bookmark)) {
            registry.bind(id, invoke: { _ in })
        }
        ActionTargetVisibility.hide("bookmark.copyLink", in: registry) { $0.target?.id == "folder" }
        func titles(_ id: String) -> [String] {
            registry.makeContextMenu(for: .bookmark, target: ActionTargetRef(kind: .bookmark, id: id)).items.map(\.title)
        }
        #expect(titles("bm").contains("Copy Bookmark Link"))
        #expect(!titles("folder").contains("Copy Bookmark Link"))
        #expect(catalog["bookmark.copyLink"]?.surfacePlan.cli == .exempt(.clipboard))
    }
}
