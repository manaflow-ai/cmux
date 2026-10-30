import CmuxNextHistory
import Foundation
import Testing

/// The Stashed page's model on its own (a stand-in source, no daemon): a failed action's notice
/// outlives the reload after it, and search filters groups and workspace members.
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
}

@MainActor
private final class FailingSource: StashPageSource {
    var failsRead = false

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
    func importGroups(_ groups: [OneTabExport.Group]) async throws -> (imported: Int, skipped: Int) { (0, 0) }
}

private nonisolated enum SourceFailure: Error, CustomStringConvertible {
    case read, restore
    var description: String { self == .read ? "list failed" : "restore failed" }
}
