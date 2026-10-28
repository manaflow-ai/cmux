import CmuxNextBridge
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Workspace hibernation's policy (plans/cmux-next/workspace-hibernation-DESIGN.md): which idle
/// workspaces leave memory, what always keeps one, how memory pressure shortens the wait, when the
/// next pass is due, how cmux.json sets it, and the warm set dropping a hibernated terminal at once.
@Suite struct WorkspaceHibernationPlannerTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static func ws(_ id: String, idleMinutes: Double?, shown: Bool = false, pinned: Bool = false, running: Bool = false,
                               attention: Bool = false, keptAwake: Bool = false, hibernated: Bool = false) -> WorkspaceHibernationPlanner.Candidate {
        WorkspaceHibernationPlanner.Candidate(
            workspace: id, lastActive: idleMinutes.map { now.addingTimeInterval(-$0 * 60) }, shown: shown, pinned: pinned,
            running: running, needsAttention: attention, keptAwake: keptAwake, hibernated: hibernated)
    }

    nonisolated static func plan(_ list: [WorkspaceHibernationPlanner.Candidate], minutes: Double = 60, enabled: Bool = true,
                                 pressure: MemoryPressureLevel = .normal) -> WorkspaceHibernationPlanner.Plan {
        WorkspaceHibernationPlanner().plan(list, policy: .init(enabled: enabled, idleMinutes: minutes), pressure: pressure, now: now)
    }

    @Test func workspacesIdlePastTheSettingHibernateIdlestFirst() {
        let list = [Self.ws("fresh", idleMinutes: 5), Self.ws("old", idleMinutes: 90), Self.ws("older", idleMinutes: 600)]
        #expect(Self.plan(list).due == ["older", "old"])
        #expect(Self.plan(list, minutes: 120).due == ["older"])
    }

    @Test func shownPinnedRunningWaitingKeptAwakeAndHibernatedWorkspacesNeverHibernate() {
        let list = [
            Self.ws("shown", idleMinutes: 999, shown: true), Self.ws("pinned", idleMinutes: 999, pinned: true),
            Self.ws("running", idleMinutes: 999, running: true), Self.ws("asks", idleMinutes: 999, attention: true),
            Self.ws("kept", idleMinutes: 999, keptAwake: true), Self.ws("asleep", idleMinutes: 999, hibernated: true),
            Self.ws("never-seen", idleMinutes: nil),
        ]
        #expect(Self.plan(list).due.isEmpty)
        #expect(Self.plan(list, pressure: .critical).due.isEmpty)
    }

    @Test func offHibernatesNothingAtAnyPressure() {
        let list = [Self.ws("old", idleMinutes: 9_999)]
        #expect(Self.plan(list, enabled: false).due.isEmpty)
        #expect(Self.plan(list, enabled: false, pressure: .critical) == WorkspaceHibernationPlanner.Plan())
    }

    @Test func memoryPressureShortensTheWait() {
        let list = [Self.ws("a", idleMinutes: 3), Self.ws("b", idleMinutes: 15), Self.ws("c", idleMinutes: 0.5)]
        #expect(Self.plan(list).due.isEmpty)
        #expect(Self.plan(list, pressure: .warning).due == ["b"])
        #expect(Self.plan(list, pressure: .critical).due == ["b", "a"])
        // A setting shorter than the pressure's wait keeps its own.
        #expect(Self.plan(list, minutes: 2, pressure: .warning).due == ["b", "a"])
    }

    @Test func theNextCheckIsTheSoonestDeadlineButNeverWithinAMinute() throws {
        let plan = Self.plan([Self.ws("soon", idleMinutes: 50), Self.ws("later", idleMinutes: 10)])
        #expect(plan.due.isEmpty)
        #expect(try #require(plan.nextCheck) == Self.now.addingTimeInterval(10 * 60))
        let almost = Self.plan([Self.ws("almost", idleMinutes: 59.9)])
        #expect(try #require(almost.nextCheck) == Self.now.addingTimeInterval(WorkspaceHibernationPlanner.minimumRecheck))
        #expect(Self.plan([Self.ws("pinned", idleMinutes: 10, pinned: true)]).nextCheck == nil)
    }

    @Test func cmuxJSONSetsTheSwitchAndTheMinutes() throws {
        func parse(_ json: String) throws -> (WorkspaceHibernationSettings, Int) {
            let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(json.utf8)), validDensities: [], validMetrics: [])
            return (snapshot.workspaceHibernation, snapshot.diagnostics.filter { $0.path.hasPrefix("workspaces.hibernation") }.count)
        }
        let defaults = try parse("{}")
        #expect(defaults.0 == WorkspaceHibernationSettings(enabled: true, idleMinutes: 60) && defaults.1 == 0)
        let set = try parse(#"{"workspaces":{"hibernation":{"enabled":false,"idleMinutes":240}}}"#)
        #expect(set.0 == WorkspaceHibernationSettings(enabled: false, idleMinutes: 240) && set.1 == 0)
        let bad = try parse(#"{"workspaces":{"hibernation":{"enabled":"yes","idleMinutes":1}}}"#)
        #expect(bad.0 == WorkspaceHibernationSettings(enabled: true, idleMinutes: 5) && bad.1 == 2)
    }

    @Test func aHibernatedTerminalLeavesTheWarmSetAtOnceButAPresentedOneStays() {
        var ledger = SurfaceLedger<String, Int>(capacity: 8)
        _ = ledger.present("idle", by: 1, ownerVisible: true)
        _ = ledger.present("shown", by: 2, ownerVisible: true)
        _ = ledger.removeOwner(1) // its workspace unmounted: hidden, still warm in the LRU
        #expect(ledger.isRetained("idle"))
        let effects = ledger.evictHidden("idle")
        #expect(effects.evicted == ["idle"])
        #expect(!ledger.isRetained("idle"))
        #expect(ledger.evictHidden("idle").isEmpty)
        #expect(ledger.evictHidden("shown").isEmpty)
        #expect(ledger.isRendering("shown"))
    }

    @Test func aPageCreatedWhileHiddenCanHibernateAndWakesFromItsSavedState() {
        var lifecycle = ContentLifecycle<String>()
        // A tab opened in the background: its page exists, no pane ever showed it. It is concealed
        // as a hidden tab is, so its hidden clock starts (it freezes like any hidden page).
        let adopted = lifecycle.send(.adopted("bg"))
        guard case .conceal("bg", let token)? = adopted.first, adopted.count == 1 else {
            Issue.record("expected one conceal, got \(adopted)"); return
        }
        #expect(lifecycle.accepts("bg", token))
        #expect(lifecycle.phase("bg") == .mountedHidden)
        // Its workspace hibernates: the page is released, and showing it restores (not a fresh mount).
        #expect(lifecycle.send(.hibernate("bg")).count == 1)
        #expect(lifecycle.phase("bg") == .hibernated)
        let effects = lifecycle.send(.show("bg"))
        guard case .restore? = effects.first else { Issue.record("expected a restore, got \(effects)"); return }
        // Adopting a tab that already has a record changes nothing.
        _ = lifecycle.send(.show("shown"))
        #expect(lifecycle.send(.adopted("shown")).isEmpty)
        #expect(lifecycle.phase("shown") == .restoring)
    }
}
