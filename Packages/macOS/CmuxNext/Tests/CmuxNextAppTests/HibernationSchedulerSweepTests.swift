@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextApp/{Hibernation,BrowserProfiles,Screenshots,Apps,Screens,LayoutTemplates} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-318): one case per migrated owner class on a
/// rig whose frames the test fires. A service's follow is a classed task that runs with no window and no node, and a
/// list read off main lands in one visible task, never inline in the read's resume.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HibernationSchedulerSweepTests {
    // MARK: ServiceObservation (AgentPageHibernation.followTurns)

    @Test func aBurstOfTurnChangesReplansInOneBackgroundTask() {
        let rig = MainDeadlineRig()
        let hibernation = AgentPageHibernation(tabs: { nil }, deadlines: rig.deadlines)
        let turns = AgentTurnStateStore()
        hibernation.followTurns(turns)
        #expect(rig.deadlines.work.postedCount(.background) == 0, "the follow's first apply was posted, not run in its turn")

        turns.watching = true
        turns.watching = false
        #expect(rig.deadlines.work.postedCount(.background) == 1, "a burst of turn changes was not one background task")
        #expect(rig.deadlines.work.postedCount(.visible) == 0, "a program's turn change took a visible task")

        rig.frame()
        #expect(rig.deadlines.work.postedCount(.background) == 0, "the turn follow did not run in its frame")
    }

    // MARK: R-hop (LayoutTemplateLibrary's launch read)

    @Test func theLaunchReadListsTheTemplatesInOneVisibleTask() async throws {
        let rig = MainDeadlineRig()
        let repository = LayoutTemplateRepository(fileURL: nil)
        _ = try await repository.put(name: "Two up", blueprint: LayoutTemplateTests.blueprint)
        let library = LayoutTemplateLibrary(repository: repository, mainWork: rig.deadlines.work)

        let read = library.beginLoad()
        let end = ContinuousClock.now + .seconds(5)
        while rig.deadlines.work.postedCount(.visible) == 0, ContinuousClock.now < end { await Task.yield() }
        #expect(rig.deadlines.work.postedCount(.visible) == 1, "the read's list was not queued as one visible task")
        #expect(library.templates.isEmpty, "the list applied in the read's resume, before its task ran")

        rig.frame()
        await read.value
        #expect(library.templates.map(\.name) == ["Two up"])
        #expect(library.beginLoad() == read, "a second load read the file again")
    }
}
