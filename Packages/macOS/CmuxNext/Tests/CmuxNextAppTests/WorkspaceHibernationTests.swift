import CmuxNextCompat
import CmuxNextHibernation
import Foundation
import Testing

/// Workspace hibernation end to end through its host seam (plans/cmux-next/workspace-hibernation-DESIGN.md):
/// a workspace hidden past the setting hibernates once and wakes when shown; the shown one, a first
/// sight and a kept-awake one stay; Hibernate Workspace refuses the shown one; memory pressure
/// hibernates at once what was hidden a while; Keep Awake lasts across launches.
@MainActor @Suite struct WorkspaceHibernationTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Host: WorkspaceHibernationHost {
        var residents: [WorkspaceHibernationResident]
        var shown: Set<String> = []
        var policy = WorkspaceHibernationPlanner.Policy(enabled: true, idleMinutes: 60)
        var hibernatedCalls: [String] = []

        init(_ ids: [String]) { residents = ids.map { WorkspaceHibernationResident(workspace: $0) } }

        func hibernationResidents() -> [WorkspaceHibernationResident] { residents }
        func hibernationShownWorkspaces() -> Set<String> { shown }
        func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy { policy }
        func hibernate(workspace: String) {
            hibernatedCalls.append(workspace)
            residents.removeAll { $0.workspace == workspace } // its memory is gone
        }
    }

    /// A deadline that never fires: each test runs its passes itself.
    final class Deadline: WorkspaceHibernationDeadline, @unchecked Sendable { // test-only; touched on the main actor alone
        var isScheduled = false
        func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) { isScheduled = true }
        func cancel() { isScheduled = false }
    }

    final class Clock {
        var now = WorkspaceHibernationTests.start
        func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
    }

    static func make(_ ids: [String], suite: String = UUID().uuidString) -> (WorkspaceHibernation, Host, Clock, UserDefaults) {
        let host = Host(ids)
        let clock = Clock()
        let defaults = UserDefaults(suiteName: "WorkspaceHibernationTests.\(suite)")!
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: Deadline(),
                                               now: { clock.now })
        return (hibernation, host, clock, defaults)
    }

    @Test func aWorkspaceHiddenPastTheSettingHibernatesOnceAndWakesWhenShown() {
        let (hibernation, host, clock, _) = Self.make(["a", "b"])
        host.shown = ["a"]
        hibernation.noteShown(["a"])
        host.shown = ["b"] // switched from a to b
        hibernation.noteShown(["b"])
        clock.advance(minutes: 59)
        hibernation.pass()
        #expect(host.hibernatedCalls.isEmpty)
        clock.advance(minutes: 2)
        hibernation.pass()
        #expect(host.hibernatedCalls == ["a"])
        #expect(hibernation.isHibernated("a"))
        hibernation.pass()
        #expect(host.hibernatedCalls == ["a"])
        // Shown again: mounted cold (resident), awake, and its clock starts over.
        host.residents.append(WorkspaceHibernationResident(workspace: "a"))
        host.shown = ["a"]
        hibernation.noteShown(["a"])
        #expect(!hibernation.isHibernated("a"))
        host.shown = ["b"]
        hibernation.noteShown(["b"])
        clock.advance(minutes: 30)
        hibernation.pass()
        #expect(host.hibernatedCalls == ["a"])
    }

    @Test func aFirstSightIsNeverIdleAndOutputKeepsAWorkspaceAwake() {
        let (hibernation, host, clock, _) = Self.make(["quiet", "busy"])
        clock.advance(minutes: 600)
        hibernation.pass() // first sight: the clock starts now
        #expect(host.hibernatedCalls.isEmpty)
        clock.advance(minutes: 50)
        host.residents[1].lastActivity = clock.now // output in "busy"
        clock.advance(minutes: 15)
        hibernation.pass()
        #expect(host.hibernatedCalls == ["quiet"])
    }

    @Test func keepAwakeAndOffKeepEveryWorkspaceAndKeepAwakeLastsAcrossLaunches() {
        let suite = UUID().uuidString
        let (hibernation, host, clock, defaults) = Self.make(["kept", "other"], suite: suite)
        #expect(hibernation.toggleKeepAwake("kept"))
        hibernation.pass()
        clock.advance(minutes: 120)
        host.policy.enabled = false
        hibernation.pass()
        #expect(host.hibernatedCalls.isEmpty)
        host.policy.enabled = true
        hibernation.pass()
        #expect(host.hibernatedCalls == ["other"])
        // The next launch reads the same set.
        #expect(WorkspaceKeepAwakeStore(defaults: defaults).contains("kept"))
        #expect(!hibernation.toggleKeepAwake("kept"))
        #expect(!WorkspaceKeepAwakeStore(defaults: defaults).contains("kept"))
    }

    @Test func hibernateWorkspaceRefusesTheShownOneAndTakesAnyOtherAtOnce() {
        let (hibernation, host, _, _) = Self.make(["shown", "fresh"])
        host.shown = ["shown"]
        hibernation.noteShown(["shown"])
        #expect(throws: WorkspaceHibernationRefusal.shown) { try hibernation.hibernateNow("shown") }
        #expect(throws: Never.self) { try hibernation.hibernateNow("fresh") }
        #expect(host.hibernatedCalls == ["fresh"])
    }

    @Test func criticalPressureHibernatesAtOnceWhatWasHiddenAMinute() {
        let (hibernation, host, clock, _) = Self.make(["a", "b"])
        host.shown = ["a", "b"]
        hibernation.noteShown(["a", "b"])
        host.shown = ["b"]
        hibernation.noteShown(["b"])
        clock.advance(minutes: 2)
        hibernation.pass()
        #expect(host.hibernatedCalls.isEmpty)
        hibernation.pressureDidChange(.critical)
        #expect(host.hibernatedCalls == ["a"])
    }
}
