import CmuxNextCompat
@testable import CmuxNextHistory
import Foundation
import Testing

/// The Stashed page's model on its own (a stand-in source, no daemon): a failed action's notice
/// outlives the reload after it, search filters groups and workspace members, a pasted OneTab
/// import closes its box only once pages went in, and each page keeps its own draft.
@MainActor @Suite struct StashPageModelTests {
    @Test func aFailedRestoreKeepsItsNoticeAfterTheReload() async throws {
        let source = FailingSource()
        let model = StashPageModel(source: source)
        await model.reload()
        let group = try #require(model.groups.first)
        await model.restore(group)
        #expect(model.notice == SourceFailure.restore.description, "the reload after the failed restore cleared its notice")

        // A failed read is said, and the next good read clears it.
        source.failsRead = true
        await model.reload()
        #expect(model.notice == SourceFailure.read.description)
        source.failsRead = false
        await model.reload()
        #expect(model.notice == nil)
    }

    @Test func searchMatchesWorkspaceNamesAndTheirTabs() async throws {
        let source = FailingSource() // the model holds its source weakly
        let model = StashPageModel(source: source)
        await model.reload()
        #expect(model.groups(matching: "deploy").map(\.id) == ["w"], "a workspace's tab title matches")
        #expect(model.groups(matching: "release work").map(\.id) == ["w"], "a workspace's name matches")
        #expect(model.groups(matching: "api.example").map(\.id) == ["w"], "a titled page's address in a workspace matches")
        #expect(model.groups(matching: "news.example").first?.tabs.map(\.id) == ["p2"], "only the matching page stays")
        #expect(model.groups(matching: " ").count == 2)
    }

    /// Text with no tab in it is said at once and never reaches the daemon; the box stays open.
    @Test func anImportOfNothingKeepsTheBoxOpenWithItsNotice() async throws {
        let source = FailingSource()
        let model = StashPageModel(source: source)
        let draft = StashImportDraft()
        draft.open()
        draft.text = "  \n\n "
        await model.importPasted(draft)
        #expect(model.notice == StashStrings.importNothing)
        #expect(draft.isOpen && draft.text == "  \n\n ", "the box closed or lost its text")
        #expect(source.importedGroups.isEmpty, "nothing to import reached the source")
    }

    /// Imported pages close the box (its text goes); none imported keeps it open with the count.
    @Test func anImportClosesTheBoxOnlyOncePagesWentIn() async throws {
        let source = FailingSource()
        let model = StashPageModel(source: source)
        let draft = StashImportDraft()
        draft.open()
        draft.text = "https://a.example/ | A\nhttps://b.example/\n\nhttps://c.example/ | C\n"
        source.importResult = (imported: 0, skipped: 3)
        await model.importPasted(draft)
        #expect(source.importedGroups == [["https://a.example/", "https://b.example/"], ["https://c.example/"]])
        #expect(model.notice == StashStrings.imported(0, skipped: 3))
        #expect(draft.isOpen, "no page went in, yet the box closed")

        source.importResult = (imported: 2, skipped: 1)
        await model.importPasted(draft)
        #expect(model.notice == StashStrings.imported(2, skipped: 1), "the reload after the import cleared its notice")
        #expect(!draft.isOpen && draft.text.isEmpty, "the box stayed open after pages went in")
    }

    /// Each Stashed page (by key) has its own search and paste box until its tab closes.
    @Test func eachPageKeepsItsOwnDraftUntilItsTabCloses() {
        let model = StashPageModel()
        let first = model.draft(for: "a")
        first.query = "docs"
        #expect(model.draft(for: "a") === first)
        #expect(model.draft(for: "b") !== first, "two pages shared one draft")
        model.dropDraft("a")
        #expect(model.draft(for: "a") !== first && model.draft(for: "a").query.isEmpty, "a closed page's draft came back")
    }
}

@MainActor
private final class FailingSource: StashPageSource {
    var failsRead = false
    var importResult = (imported: 0, skipped: 0)
    /// The addresses of each group every import got, in order.
    private(set) var importedGroups: [[String]] = []

    func stashes() async throws -> [StashedGroup] {
        if failsRead { throw SourceFailure.read }
        return [
            StashedGroup(id: "w", name: nil, createdAt: .now, tabs: [
                .init(id: "w1", kind: .workspace(tabs: ["deploy logs", "Docs"], addresses: ["https://api.example/reference"]), url: "", title: "Release work", profile: nil),
            ]),
            StashedGroup(id: "p", name: "Reading", createdAt: .now, tabs: [
                .init(id: "p1", url: "https://docs.example/", title: "Docs", profile: nil),
                .init(id: "p2", url: "https://news.example/", title: "News", profile: nil),
            ]),
        ]
    }

    func restore(_ group: StashedGroup, tabs: [StashedGroup.Tab], inNewWorkspace: Bool) async throws { throw SourceFailure.restore }
    func delete(_ group: StashedGroup, tabs: [StashedGroup.Tab]?) async throws {}
    func importGroups(_ groups: [OneTabExport.Group]) async throws -> (imported: Int, skipped: Int) {
        importedGroups += groups.map { $0.tabs.map(\.url) }
        return importResult
    }
}

private nonisolated enum SourceFailure: Error, CustomStringConvertible {
    case read, restore
    var description: String { self == .read ? "list failed" : "restore failed" }
}
