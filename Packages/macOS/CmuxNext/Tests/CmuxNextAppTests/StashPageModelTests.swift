import CmuxNextHistory
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The Stashed page's model on its own (a stand-in source, no daemon): a failed action's notice
/// outlives the reload after it, search filters groups and workspace members, and a click shows in its own turn
/// while the daemon call runs after it and ends as one userBlocking task (recipe R-hop).
@MainActor @Suite struct StashPageModelTests {
    @Test func aFailedRestoreKeepsItsNoticeAfterTheReload() async throws {
        let source = FailingSource()
        let model = StashPageModel(source: source, mainWork: taskTurnMainWork())
        await model.reload()
        let group = try #require(model.groups.first)
        await model.restore(group)?.value
        #expect(model.notice == SourceFailure.restore.description, "the reload after the failed restore cleared its notice")

        // A failed read is said, and the next good read clears it.
        source.failsRead = true
        await model.reload()
        #expect(model.notice == SourceFailure.read.description)
        source.failsRead = false
        await model.reload()
        #expect(model.notice == nil)
    }

    /// A click disables the page in its own turn and makes no daemon call there; the call runs after the turn, and
    /// the op's end (the notice of its failure, the page enabled again) runs as one userBlocking main task.
    @Test func aClickShowsInItsTurnAndEndsAsAUserBlockingTask() async throws {
        let work = taskTurnMainWork()
        let source = FailingSource()
        let model = StashPageModel(source: source, mainWork: work)
        let group = StashedGroup(id: "p", name: "Reading", createdAt: .now, tabs: [
            .init(id: "p1", url: "https://docs.example/", title: "Docs", profile: nil),
        ])
        let seen = NoticeClass()
        withObservationTracking { _ = model.notice } onChange: {
            MainActor.assumeIsolated { seen.workClass = work.board.running?.workClass }
        }

        let op = try #require(model.restore(group))
        #expect(model.isBusy, "the click did not disable the page in its turn")
        #expect(source.restores == 0, "the daemon call ran in the click's turn")
        await op.value
        #expect(source.restores == 1)
        #expect(!model.isBusy, "the page stayed disabled after its op landed")
        #expect(model.notice == SourceFailure.restore.description)
        #expect(seen.workClass == .userBlocking, "the op's end ran as \(String(describing: seen.workClass)), not userBlocking")
    }

    @Test func searchMatchesWorkspaceNamesAndTheirTabs() async throws {
        let source = FailingSource() // the model holds its source weakly
        let model = StashPageModel(source: source, mainWork: taskTurnMainWork())
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
    /// Restores asked for so far.
    var restores = 0

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

    func restore(_ group: StashedGroup, tabs: [StashedGroup.Tab], inNewWorkspace: Bool) async throws {
        restores += 1
        throw SourceFailure.restore
    }
    func delete(_ group: StashedGroup, tabs: [StashedGroup.Tab]?) async throws {}
    func importGroups(_ groups: [OneTabExport.Group]) async throws -> (imported: Int, skipped: Int) { (0, 0) }
}

private nonisolated enum SourceFailure: Error, CustomStringConvertible {
    case read, restore
    var description: String { self == .read ? "list failed" : "restore failed" }
}

/// The class of the main task that changed the page's notice.
@MainActor private final class NoticeClass {
    var workClass: MainWorkClass?
}
