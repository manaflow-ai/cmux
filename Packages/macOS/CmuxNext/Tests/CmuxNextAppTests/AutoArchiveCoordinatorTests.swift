@testable import CmuxNextSidebar
import Foundation
import Testing

/// Auto-archive end to end through its seams (plans/cmux-next/auto-archive-DESIGN.md): what a pass
/// does under each style, the toast's Undo, the suggestion card's Archive and Not Now, a workspace
/// it archived coming back when shown, the sweep's refusal, and a first sight never counting as idle.
@MainActor @Suite struct AutoArchiveCoordinatorTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    /// A document of loose workspaces whose `setArchived` marks its own records.
    final class Document: AutoArchiveDocument {
        var records: SidebarDocRecords
        var sent: [(items: [String], archived: Bool)] = []

        init(workspaces: [String]) {
            var items: [String: SidebarDocItem] = [:]
            for id in workspaces {
                items["itm_\(id)"] = SidebarDocItem(id: "itm_\(id)", section: "sec_m_s", body: .workspace(SidebarDocWorkspaceRef(sessionID: "s", workspaceID: id)))
            }
            records = SidebarDocRecords(sections: [:], items: items)
        }

        func setArchived(_ items: [String], archived: Bool, title: String) throws(SidebarDocSendRefusal) {
            sent.append((items, archived))
            for item in items { records.items[item]?.archived = archived }
        }
    }

    final class Host: AutoArchiveHost {
        var active: [String: Date?] = [:]
        var shown: Set<String> = []
        var policy = AutoArchivePolicy(style: .quiet, idleDays: 3)
        var toasts: [(String, @MainActor () -> Void)] = []
        var cards: [SidebarNoticeCard] = []
        var answer = true

        func autoArchiveCandidates() -> [AutoArchivePlanner.Candidate] {
            active.keys.sorted().map { AutoArchivePlanner.Candidate(item: "itm_\($0)", workspace: $0, title: $0.uppercased(), lastActive: active[$0] ?? nil) }
        }
        func autoArchiveShownWorkspaces() -> Set<String> { shown }
        func autoArchivePolicy() -> AutoArchivePolicy { policy }
        func autoArchiveToast(_ message: String, undo: @escaping @MainActor () -> Void) { toasts.append((message, undo)) }
        func autoArchiveAsk(_ card: SidebarNoticeCard) async -> Bool {
            cards.append(card)
            return answer
        }
        func autoArchiveItem(workspace id: String) -> String? { "itm_\(id)" }
    }

    let host = Host()
    let document: Document
    let coordinator: AutoArchiveCoordinator

    init() {
        document = Document(workspaces: ["fresh", "old", "older"])
        host.active = ["fresh": Self.start.addingTimeInterval(-1 * Self.day), "old": Self.start.addingTimeInterval(-4 * Self.day),
                       "older": Self.start.addingTimeInterval(-40 * Self.day)]
        let defaults = UserDefaults(suiteName: "AutoArchiveCoordinatorTests.\(UUID().uuidString)") ?? UserDefaults()
        let document = document
        let now = Self.start
        coordinator = AutoArchiveCoordinator(host: host, document: { document }, ledgerStore: AutoArchiveLedgerStore(defaults: defaults),
                                             now: { now })
    }

    func archived() -> Set<String> { Set(document.records.items.values.filter(\.archived).map(\.id)) }

    @Test func quietArchivesTheIdleOnesInOneStepAndUndoBringsThemBack() throws {
        coordinator.runPass()
        #expect(archived() == ["itm_old", "itm_older"])
        #expect(document.sent.count == 1, "one change, one undo step")
        let toast = try #require(host.toasts.first)
        #expect(toast.0.contains("2"))
        toast.1()
        #expect(archived().isEmpty)
    }

    @Test func offAndManualDoNothingInTheBackground() {
        for style in [AutoArchivePolicy.Style.off, .manual] {
            host.policy.style = style
            coordinator.runPass()
        }
        #expect(document.sent.isEmpty && host.toasts.isEmpty && host.cards.isEmpty)
    }

    @Test func suggestAsksFirstAndArchivesOnArchive() async throws {
        host.policy.style = .suggest
        coordinator.runPass()
        try await waitFor { !host.cards.isEmpty && !document.sent.isEmpty }
        #expect(host.cards.first?.lines == ["OLDER", "OLD"])
        #expect(archived() == ["itm_old", "itm_older"])
    }

    @Test func notNowSnoozesTheCardForADay() async throws {
        host.policy.style = .suggest
        host.answer = false
        coordinator.runPass()
        try await waitFor { host.cards.count == 1 }
        await Task.yield()
        coordinator.runPass()
        await Task.yield()
        #expect(host.cards.count == 1, "no second card while snoozed")
        #expect(archived().isEmpty)
    }

    @Test func aWorkspaceItArchivedComesBackWhenShownAndOneArchivedByHandDoesNot() throws {
        coordinator.runPass()
        try document.setArchived(["itm_fresh"], archived: true, title: "by hand")
        coordinator.noteShown(["old", "fresh"])
        #expect(!archived().contains("itm_old"), "auto-archived and shown: back")
        #expect(archived().contains("itm_fresh"), "archived by hand keeps Aziz's rule: it opens dimmed")
    }

    @Test func shownAndNeverSeenWorkspacesStay() {
        host.shown = ["older"]
        host.active["new"] = .some(nil)
        document.records.items["itm_new"] = SidebarDocItem(id: "itm_new", section: "sec_m_s", body: .workspace(SidebarDocWorkspaceRef(sessionID: "s", workspaceID: "new")))
        coordinator.runPass()
        #expect(archived() == ["itm_old"])
    }

    @Test func theSweepArchivesUnderManualAndRefusesWhenNothingIsIdle() throws {
        host.policy.style = .manual
        #expect(try coordinator.sweep() == 2)
        #expect(throws: AutoArchiveRefusal.self) { try coordinator.sweep() }
    }

    @Test func theArchivedListShowsWhatIsArchivedLastUsedFirst() throws {
        coordinator.runPass()
        #expect(coordinator.archivedWorkspaces().map(\.workspace) == ["old", "older"])
        coordinator.restore(["itm_old"])
        #expect(coordinator.archivedWorkspaces().map(\.workspace) == ["older"])
    }

    /// Waits for the card task (its own `Task`) to run, a turn at a time; never sleeps.
    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { await Task.yield() }
        try #require(condition())
    }
}
