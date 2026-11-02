@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Hidden-space hibernation (leo-workspace design/spaces.md "Hibernation and the perf plan", cmux
/// plans/cmux-next/workspace-hibernation-DESIGN.md): a space no window shows is hidden, and its idle
/// workspaces hibernate on the shorter hidden-space clock with the same exemptions; a workspace of a
/// shown space keeps the normal clock.
@Suite struct HiddenSpaceHibernationTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static func ws(_ id: String, idleMinutes: Double?, hiddenSpace: Bool, shown: Bool = false, pinned: Bool = false,
                               running: Bool = false, attention: Bool = false, keptAwake: Bool = false,
                               hibernated: Bool = false) -> WorkspaceHibernationPlanner.Candidate {
        WorkspaceHibernationPlanner.Candidate(
            workspace: id, lastActive: idleMinutes.map { now.addingTimeInterval(-$0 * 60) }, shown: shown, pinned: pinned,
            running: running, needsAttention: attention, keptAwake: keptAwake, hibernated: hibernated, inHiddenSpace: hiddenSpace)
    }

    nonisolated static func plan(_ list: [WorkspaceHibernationPlanner.Candidate], minutes: Double = 60, hiddenSpaceMinutes: Double = 15,
                                 enabled: Bool = true, pressure: MemoryPressureLevel = .normal) -> WorkspaceHibernationPlanner.Plan {
        WorkspaceHibernationPlanner().plan(
            list, policy: .init(enabled: enabled, idleMinutes: minutes, hiddenSpaceIdleMinutes: hiddenSpaceMinutes),
            pressure: pressure, now: now)
    }

    @Test func aHiddenSpaceWorkspacePastTheHiddenThresholdHibernatesAShownSpaceOneDoesNot() {
        let list = [Self.ws("hidden-space", idleMinutes: 20, hiddenSpace: true), Self.ws("shown-space", idleMinutes: 20, hiddenSpace: false)]
        #expect(Self.plan(list).due == ["hidden-space"])
        // Both clocks still run: the shown space's workspace goes at the normal setting.
        #expect(Self.plan(list, minutes: 15).due.sorted() == ["hidden-space", "shown-space"])
        // Not yet past the hidden threshold.
        #expect(Self.plan([Self.ws("fresh", idleMinutes: 10, hiddenSpace: true)]).due.isEmpty)
    }

    @Test func theExemptionsHoldInAHiddenSpace() {
        let list = [
            Self.ws("shown", idleMinutes: 999, hiddenSpace: true, shown: true),
            Self.ws("pinned", idleMinutes: 999, hiddenSpace: true, pinned: true),
            Self.ws("running", idleMinutes: 999, hiddenSpace: true, running: true),
            Self.ws("asks", idleMinutes: 999, hiddenSpace: true, attention: true),
            Self.ws("kept", idleMinutes: 999, hiddenSpace: true, keptAwake: true),
            Self.ws("asleep", idleMinutes: 999, hiddenSpace: true, hibernated: true),
            Self.ws("never-seen", idleMinutes: nil, hiddenSpace: true),
        ]
        #expect(Self.plan(list).due.isEmpty)
        #expect(Self.plan(list, pressure: .critical).due.isEmpty)
        #expect(Self.plan([Self.ws("old", idleMinutes: 999, hiddenSpace: true)], enabled: false) == WorkspaceHibernationPlanner.Plan())
    }

    @Test func theShorterOfTheTwoSettingsAndMemoryPressureWin() {
        // A hidden-space setting longer than the normal one never keeps a hidden space's workspace longer.
        #expect(Self.plan([Self.ws("a", idleMinutes: 40, hiddenSpace: true)], minutes: 30, hiddenSpaceMinutes: 120).due == ["a"])
        // Critical pressure shortens the hidden clock too.
        #expect(Self.plan([Self.ws("a", idleMinutes: 2, hiddenSpace: true)], pressure: .critical).due == ["a"])
    }

    @Test func theNextCheckIsTheHiddenSpaceDeadline() throws {
        let plan = Self.plan([Self.ws("shown-space", idleMinutes: 10, hiddenSpace: false), Self.ws("hidden-space", idleMinutes: 10, hiddenSpace: true)])
        #expect(plan.due.isEmpty)
        #expect(try #require(plan.nextCheck) == Self.now.addingTimeInterval(5 * 60))
    }

    @Test func cmuxJSONSetsTheHiddenSpaceMinutes() throws {
        func parse(_ json: String) throws -> (WorkspaceHibernationSettings, Int) {
            let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(json.utf8)), validDensities: [], validMetrics: [])
            return (snapshot.workspaceHibernation, snapshot.diagnostics.filter { $0.path.hasPrefix("workspaces.hibernation") }.count)
        }
        let defaults = try parse("{}")
        #expect(defaults.0.hiddenSpaceMinutes == WorkspaceHibernationSettings.hiddenSpaceMinutesDefault && defaults.1 == 0)
        #expect(WorkspaceHibernationPlanner.Policy(defaults.0).hiddenSpaceIdleMinutes == WorkspaceHibernationSettings.hiddenSpaceMinutesDefault)
        let set = try parse(#"{"workspaces":{"hibernation":{"hiddenSpaceMinutes":30}}}"#)
        #expect(set.0.hiddenSpaceMinutes == 30 && set.1 == 0)
        let bad = try parse(#"{"workspaces":{"hibernation":{"hiddenSpaceMinutes":1}}}"#)
        #expect(bad.0.hiddenSpaceMinutes == 5 && bad.1 == 1)
    }

    @Test func aSpaceIsHiddenWhenNoWindowShowsAnyRoomOfTheWorkspace() {
        let work: ProfileID = "work", play: ProfileID = "play"
        let pinned = RoomMembership.Workspace(session: "home", key: "pinned-to-work")
        let followed = RoomMembership.Workspace(session: "laptop", key: "w1")
        let loose = RoomMembership.Workspace(session: "other", key: "w2")
        let membership = RoomMembership(follows: [work: ["laptop"], play: ["laptop"]], pins: ["home": ["pinned-to-work": work]])
        #expect(membership.isHidden(pinned, shown: [play, .defaultProfile]))
        #expect(!membership.isHidden(pinned, shown: [work]))
        // Followed by two spaces: hidden only when neither shows.
        #expect(!membership.isHidden(followed, shown: [play]))
        #expect(membership.isHidden(followed, shown: [.defaultProfile]))
        // In no space: it shows in default.
        #expect(!membership.isHidden(loose, shown: [.defaultProfile]))
        #expect(membership.isHidden(loose, shown: [work]))
    }
}

/// The coordinator hands the hidden-space flag from its host to the planner.
@MainActor @Suite struct HiddenSpaceHibernationCoordinatorTests {
    final class Host: WorkspaceHibernationHost {
        var residents: [WorkspaceHibernationResident]
        var policy = WorkspaceHibernationPlanner.Policy(enabled: true, idleMinutes: 60, hiddenSpaceIdleMinutes: 15)
        var hibernatedCalls: [String] = []
        init(_ residents: [WorkspaceHibernationResident]) { self.residents = residents }
        func hibernationResidents() -> [WorkspaceHibernationResident] { residents }
        var shown: Set<String> = []
        func hibernationShownWorkspaces() -> Set<String> { shown }
        var spaces: Set<String> = []
        func hibernationShownSpaces() -> Set<String> { spaces }
        func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy { policy }
        func hibernate(workspace: String) {
            hibernatedCalls.append(workspace)
            residents.removeAll { $0.workspace == workspace }
        }
    }

    final class Deadline: WorkspaceHibernationDeadline, @unchecked Sendable { // test-only; touched on the main actor alone
        var isScheduled = false
        var delays: [Duration] = []
        func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) {
            isScheduled = true
            delays.append(delay)
        }
        func cancel() { isScheduled = false }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @Test func aHiddenSpacesIdleWorkspaceHibernatesOnTheHiddenClock() {
        let clock = Clock()
        let host = Host([WorkspaceHibernationResident(workspace: "hidden", inHiddenSpace: true),
                         WorkspaceHibernationResident(workspace: "shown-space")])
        let suite = "HiddenSpaceHibernationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: Deadline(),
                                               now: { clock.now })
        hibernation.pass() // first sight starts both clocks
        clock.now = clock.now.addingTimeInterval(16 * 60)
        hibernation.pass()
        #expect(host.hibernatedCalls == ["hidden"])
        clock.now = clock.now.addingTimeInterval(45 * 60)
        hibernation.pass()
        #expect(host.hibernatedCalls == ["hidden", "shown-space"])
    }

    /// A window switching space hides a workspace while a later deadline is pending (planned on the old shown
    /// set, at the normal clock): the switch re-arms the deadline a minute out, so the hidden-space clock is not
    /// overslept by the pending one.
    @Test func aSwitchThatHidesASpaceReArmsAPendingLaterDeadline() {
        let clock = Clock()
        let host = Host([WorkspaceHibernationResident(workspace: "a"), WorkspaceHibernationResident(workspace: "b")])
        let suite = "HiddenSpaceHibernationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let deadline = Deadline()
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: deadline,
                                               now: { clock.now })
        host.shown = ["a"]
        hibernation.noteShown(["a"])
        hibernation.pass() // b's normal deadline is armed, an hour out
        #expect(deadline.isScheduled)
        deadline.delays = []
        host.shown = []
        hibernation.noteShown([]) // the window switched to another space: a is hidden, and its space with it
        #expect(deadline.delays == [.seconds(Int64(WorkspaceHibernationPlanner.minimumRecheck))])
    }

    /// Switching back and forth keeps hiding workspaces: an armed deadline that is already due sooner is never
    /// pushed out, so the pass still comes (the review's starvation case).
    @Test func repeatedSwitchesNeverPostponeAnArmedPass() {
        let clock = Clock()
        let host = Host([WorkspaceHibernationResident(workspace: "a"), WorkspaceHibernationResident(workspace: "b")])
        let suite = "HiddenSpaceHibernationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let deadline = Deadline()
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: deadline,
                                               now: { clock.now })
        host.shown = ["a"]
        hibernation.noteShown(["a"])
        host.shown = ["b"]
        hibernation.noteShown(["b"]) // a hidden: a pass a minute out
        #expect(deadline.delays.count == 1)
        clock.advance(seconds: 30)
        host.shown = ["a"]
        hibernation.noteShown(["a"])
        host.shown = ["b"]
        hibernation.noteShown(["b"]) // hidden again 30 s later: the pass due in 30 s stays
        #expect(deadline.delays.count == 1)
    }

    /// Closing the last window that shows a space hides it with no observable change (`WindowManager.controllers`
    /// is not observable, so the shown-set follow can miss it): the window lifecycle hook re-reads the shown sets
    /// and plans a pass within a minute, ahead of the pending normal deadline, and never pushes out a sooner one (#30854).
    @Test func closingTheLastWindowOfASpaceReArmsAPendingLaterDeadline() {
        let clock = Clock()
        let host = Host([WorkspaceHibernationResident(workspace: "a"), WorkspaceHibernationResident(workspace: "b")])
        let suite = "HiddenSpaceHibernationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let deadline = Deadline()
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: deadline,
                                               now: { clock.now })
        host.shown = ["a"]
        host.spaces = ["work", "play"]
        hibernation.windowsDidChange() // two windows opened, one per space
        hibernation.pass() // b's normal deadline is armed, an hour out
        #expect(deadline.isScheduled)
        deadline.delays = []
        host.spaces = ["work"] // the play window closed; a is still shown in work
        hibernation.windowsDidChange()
        #expect(deadline.delays == [.seconds(Int64(WorkspaceHibernationPlanner.minimumRecheck))])
        clock.advance(seconds: 30)
        host.spaces = ["work", "play"]
        hibernation.windowsDidChange() // reopened: hides nothing
        host.spaces = ["work"]
        hibernation.windowsDidChange() // closed again 30 s later: the pass due in 30 s stays
        #expect(deadline.delays.count == 1)
    }

    /// A window switching to a space that shows the same workspace changes no shown workspace but hides a
    /// space: that alone plans a pass within a minute.
    @Test func aSpaceThatGoesHiddenPlansAPassEvenWithTheSameShownWorkspaces() {
        let clock = Clock()
        let host = Host([WorkspaceHibernationResident(workspace: "a")])
        let suite = "HiddenSpaceHibernationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let deadline = Deadline()
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: deadline,
                                               now: { clock.now })
        hibernation.noteShownSpaces(["work"])
        #expect(deadline.delays.isEmpty)
        hibernation.noteShownSpaces(["work", "play"])
        #expect(deadline.delays.isEmpty) // a space shown in one more window hides nothing
        hibernation.noteShownSpaces(["play"])
        #expect(deadline.delays == [.seconds(Int64(WorkspaceHibernationPlanner.minimumRecheck))])
    }
}
