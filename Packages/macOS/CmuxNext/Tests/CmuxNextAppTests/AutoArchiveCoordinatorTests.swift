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
        var answer: String? = "archive"
        var styles: [AutoArchivePolicy.Style] = []

        func autoArchiveCandidates() -> [AutoArchivePlanner.Candidate] {
            active.keys.sorted().map { AutoArchivePlanner.Candidate(item: "itm_\($0)", workspace: $0, title: $0.uppercased(), lastActive: active[$0] ?? nil) }
        }
        func autoArchiveShownWorkspaces() -> Set<String> { shown }
        func autoArchivePolicy() -> AutoArchivePolicy { policy }
        func autoArchiveToast(_ message: String, undo: @escaping @MainActor () -> Void) { toasts.append((message, undo)) }
        func autoArchiveSetStyle(_ style: AutoArchivePolicy.Style) async {
            styles.append(style)
            policy.style = style
        }
        func autoArchiveAsk(_ card: SidebarNoticeCard) async -> String? {
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

    /// Lawrence 18515/18517: the Tidy Up card popping up on its own was annoying. With no
    /// `workspaces.autoArchive.style` set, a pass neither asks nor archives; Archive Idle Workspaces
    /// still archives on request.
    @Test func theDefaultStyleNeverPopsACardOrArchivesOnItsOwn() async throws {
        host.policy = AutoArchivePolicy(styleName: nil, idleDays: nil)
        coordinator.runPass()
        await Task.yield()
        await Task.yield()
        #expect(host.cards.isEmpty, "no card on its own")
        #expect(document.sent.isEmpty && host.toasts.isEmpty)
        #expect(try coordinator.sweep() == 2, "Archive Idle Workspaces still works")
    }

    @Test func suggestAsksFirstAndArchivesOnArchive() async throws {
        host.policy.style = .suggest
        coordinator.runPass()
        try await waitFor { !host.cards.isEmpty && !document.sent.isEmpty }
        #expect(host.cards.first?.lines == ["OLDER", "OLD"])
        #expect(archived() == ["itm_old", "itm_older"])
    }

    @Test func theCardIsOneQuestionWithArchiveAndAlwaysArchive() async throws {
        host.policy.style = .suggest
        host.answer = "always"
        coordinator.runPass()
        try await waitFor { !host.cards.isEmpty && !document.sent.isEmpty }
        let card = try #require(host.cards.first)
        #expect(card.title == "2 idle workspaces", "the button says Archive; the title fits the sidebar (a capture cut \"Archive 6 idle workspa…\")")
        #expect(card.eyebrow == nil && card.detail == nil, "no heading, no paragraph")
        #expect(card.actions.map(\.id) == ["archive", "always"])
        #expect(card.actions.map(\.isSwitch) == [false, true], "T3: Always is an inline switch, not a button")
        #expect(host.styles == [.quiet], "Always Archive turns on automatic archiving")
        #expect(archived() == ["itm_old", "itm_older"])
    }

    /// Lawrence 18519 ("grammar", a card reading "1 workspaces look idle"): one idle workspace reads
    /// in the singular on the card and on the toast; two read in the plural.
    @Test func oneIdleWorkspaceReadsInTheSingular() async throws {
        host.active["old"] = .some(Self.start.addingTimeInterval(-1 * Self.day))
        host.policy.style = .suggest
        coordinator.runPass()
        try await waitFor { !host.cards.isEmpty && !document.sent.isEmpty }
        #expect(host.cards.first?.title == "1 idle workspace")
        #expect(host.cards.first?.lines == ["OLDER"])
        #expect(host.toasts.first?.0 == "Archived 1 idle workspace")
    }

    @Test func twoIdleWorkspacesReadInThePlural() throws {
        coordinator.runPass()
        #expect(host.toasts.first?.0 == "Archived 2 idle workspaces")
    }

    @Test func notNowSnoozesTheCardForADay() async throws {
        host.policy.style = .suggest
        host.answer = nil
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
