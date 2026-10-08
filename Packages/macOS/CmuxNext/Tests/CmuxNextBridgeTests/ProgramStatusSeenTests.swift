import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// OSC 7501 `done` and `error` show until seen (contract
/// .cmux-scratch/nx-osc7501/CONTRACT.md: each client keeps its own seen set
/// keyed by terminal, record id and `updated_seq`).
struct ProgramStatusSeenTests {
    static let done = ProgramStatusRecord(id: "build", state: .done, updatedSeq: 4)
    static let error = ProgramStatusRecord(id: "test", state: .error, updatedSeq: 5)
    static let working = ProgramStatusRecord(id: "lint", state: .working, updatedSeq: 6)
    static let blocked = ProgramStatusRecord(id: "deploy", state: .blocked, kind: .permission, updatedSeq: 7)

    @Test func doneAndErrorStayUntilSeen() {
        var seen = ProgramStatusSeen()
        let records = [Self.done, Self.error, Self.working, Self.blocked]
        #expect(seen.visible(records, terminal: "t1") == records)
        let changed = seen.markSeen(records, terminal: "t1")
        #expect(changed)
        // Working and blocked are live states, never hidden by a look.
        #expect(seen.visible(records, terminal: "t1") == [Self.working, Self.blocked])
        // Another terminal's records with the same ids are not seen.
        #expect(seen.visible(records, terminal: "t2") == records)
        // Nothing new: marking again changes nothing.
        let changedAgain = seen.markSeen(records, terminal: "t1")
        #expect(!changedAgain)
    }

    @Test func aNewReportIsUnseenAgain() {
        var seen = ProgramStatusSeen()
        seen.markSeen([Self.error], terminal: "t1")
        var again = Self.error
        again.updatedSeq = 12
        #expect(seen.visible([again], terminal: "t1") == [again])
    }

    @Test func seenKeysOfRecordsThatLeftArePruned() {
        var seen = ProgramStatusSeen()
        seen.markSeen([Self.done, Self.error], terminal: "t1")
        seen.markSeen([Self.error], terminal: "t1")
        #expect(seen.count == 1)
        seen.markSeen([], terminal: "t1")
        #expect(seen.count == 0)
    }

    @Test func theSeenSetIsBounded() {
        var seen = ProgramStatusSeen()
        for index in 0..<(ProgramStatusSeen.limit + 10) {
            seen.markSeen([ProgramStatusRecord(state: .done, updatedSeq: UInt64(index))], terminal: "t\(index)")
        }
        #expect(seen.count == ProgramStatusSeen.limit)
        // The oldest keys leave first.
        #expect(seen.visible([ProgramStatusRecord(state: .done, updatedSeq: 0)], terminal: "t0").count == 1)
        let last = ProgramStatusSeen.limit + 9
        #expect(seen.visible([ProgramStatusRecord(state: .done, updatedSeq: UInt64(last))], terminal: "t\(last)").isEmpty)
    }

    @MainActor @Test func theStoreSurvivesARelaunchThroughItsDefaults() throws {
        let suite = "cmux.tests.programStatusSeen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ProgramStatusSeenStore()
        first.persist(to: defaults)
        first.markSeen([Self.done], terminal: "t1")
        let second = ProgramStatusSeenStore()
        second.persist(to: defaults)
        #expect(second.visible([Self.done], terminal: "t1").isEmpty)
    }
}

/// The tab badge, the tab summary and the workspace row show an unseen
/// `error` (error mark) and an unseen `done` (done mark); looking at the
/// terminal clears both.
@MainActor
struct ProgramStatusSeenIndicatorTests {
    @Test func unseenErrorAndDoneMarkTheTabAndTheRowUntilSeen() throws {
        let store = try BridgeFixture.store()
        let workspace = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let tab = try #require(workspace.screens.flatMap(\.panes).flatMap(\.tabs).first)
        let seen = ProgramStatusSeenStore()
        let mapping = StatusMapping(seen: seen)

        tab.programStatus = [ProgramStatusRecord(id: "test", state: .error, title: "Tests", updatedSeq: 9101)]
        #expect(mapping.summary(tab).state == .error)
        #expect(mapping.summary(tabs: [tab]).state == .error)
        #expect(mapping.outcome(tab) == .failure)
        seen.markSeen(tab)
        #expect(mapping.summary(tab) == .idle)
        #expect(mapping.outcome(tab) == nil)

        tab.programStatus = [ProgramStatusRecord(id: "build", state: .done, updatedSeq: 9102)]
        #expect(mapping.summary(tab).state == .success)
        #expect(mapping.outcome(tab) == .success)
        seen.markSeen(tab)
        #expect(mapping.summary(tab) == .idle)
        #expect(mapping.outcome(tab) == nil)
    }

    /// A seen failure does not hide a later record of the same terminal.
    @Test func aSeenErrorGivesWayToTheNextStrongestRecord() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        let seen = ProgramStatusSeenStore()
        let mapping = StatusMapping(seen: seen)
        tab.programStatus = [ProgramStatusRecord(id: "test", state: .error, updatedSeq: 9201)]
        seen.markSeen(tab)
        tab.programStatus.append(ProgramStatusRecord(id: "build", state: .working, progress: 50, updatedSeq: 9202))
        #expect(mapping.loading(tab).state == .working(progress: 0.5))
        #expect(mapping.outcome(tab) == nil)
    }

    @Test func theTabStripItemShowsTheUnseenOutcome() throws {
        let store = try BridgeFixture.store()
        let tab = try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
        tab.programStatus = [ProgramStatusRecord(id: "strip", state: .error, updatedSeq: 9301)]
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .failure)
        ProgramStatusSeenStore.shared.markSeen(tab)
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .none)
    }
}
