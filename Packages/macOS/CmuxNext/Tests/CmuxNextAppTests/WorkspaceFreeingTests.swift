import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// The freeing tier under hibernation (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md): a hibernated
/// workspace's shell that sits at an empty prompt past `workspaces.freeing.idleMinutes` is parked; anything the
/// planner cannot prove idle keeps running.
@MainActor @Suite struct WorkspaceFreeingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day = 24.0 * 60 * 60
    static let on = WorkspaceFreeingPlanner.Policy(enabled: true, idleMinutes: 1440)

    static func idle(_ surface: String, workspace: String = "w", hoursAgo: Double = 30) -> WorkspaceFreeingPlanner.Terminal {
        let at = now.addingTimeInterval(-hoursAgo * 3600)
        return WorkspaceFreeingPlanner.Terminal(surface: surface, workspace: workspace, workspaceLastActive: at,
                                                promptSince: at, lastOutput: at)
    }

    // MARK: Planner

    @Test func aShellAtItsPromptPastTheSettingFrees() {
        #expect(WorkspaceFreeingPlanner().plan([Self.idle("t1")], policy: Self.on, now: Self.now).due == ["t1"])
    }

    @Test func offFreesNothing() {
        let off = WorkspaceFreeingPlanner.Policy(enabled: false, idleMinutes: 1440)
        #expect(WorkspaceFreeingPlanner().plan([Self.idle("t1")], policy: off, now: Self.now) == .init())
    }

    @Test func theDefaultIsOffAndOneDay() {
        let settings = WorkspaceHibernationSettings()
        #expect(settings.freeingEnabled == false)
        #expect(settings.freeingIdleMinutes == 1440)
    }

    @Test(arguments: ["running", "noPrompt", "program", "attached", "remote", "kept", "awake", "ended"])
    func everyFactThatKeepsAShellRunningKeepsIt(_ fact: String) {
        var terminal = Self.idle("t1")
        switch fact {
        case "running", "noPrompt": terminal.promptSince = nil
        case "program": terminal.programReported = true
        case "attached": terminal.attached = true
        case "remote": terminal.local = false
        case "kept": terminal.workspaceKept = true
        case "awake": terminal.hibernated = false
        default: terminal.ended = true
        }
        #expect(WorkspaceFreeingPlanner().plan([terminal], policy: Self.on, now: Self.now).due.isEmpty)
    }

    @Test func recentOutputOrUseKeepsItAndSaysWhenToLookAgain() throws {
        var terminal = Self.idle("t1")
        terminal.lastOutput = Self.now.addingTimeInterval(-3600) // printed an hour ago
        let plan = WorkspaceFreeingPlanner().plan([terminal], policy: Self.on, now: Self.now)
        #expect(plan.due.isEmpty)
        #expect(try #require(plan.nextCheck) == Self.now.addingTimeInterval(Self.day - 3600))
    }

    @Test func theLongestIdleFreesFirst() {
        let plan = WorkspaceFreeingPlanner().plan([Self.idle("new", hoursAgo: 25), Self.idle("old", hoursAgo: 90)], policy: Self.on, now: Self.now)
        #expect(plan.due == ["old", "new"])
    }

    @Test func settingsParseTheFreeingKeys() throws {
        let json = #"{"workspaces":{"hibernation":{"idleMinutes":90},"freeing":{"enabled":true,"idleMinutes":120}}}"#
        let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(json.utf8)), validDensities: [], validMetrics: [])
        let settings = snapshot.workspaceHibernation
        #expect(settings.freeingEnabled && settings.freeingIdleMinutes == 120)
        #expect(settings.idleMinutes == 90, "the hibernation keys still parse beside them")
        #expect(WorkspaceFreeingPlanner.Policy(settings) == .init(enabled: true, idleMinutes: 120))
        #expect(WorkspaceHibernationPlanner.Policy(settings).freeing == .init(enabled: true, idleMinutes: 120),
                "the hibernation policy carries the freeing tier's")
    }

    // MARK: Agents and running commands

    /// An agent TUI idle past the setting (its prompt is not a shell's: no OSC 133 A).
    static func agent(_ surface: String, _ agent: WorkspaceFreeingPlanner.Terminal.Agent) -> WorkspaceFreeingPlanner.Terminal {
        var terminal = idle(surface)
        terminal.promptSince = nil
        terminal.commandSince = terminal.lastOutput
        terminal.programReported = true
        terminal.agent = agent
        return terminal
    }

    /// A command that still runs, quiet past the setting (a stalled dev server).
    static func running(_ surface: String) -> WorkspaceFreeingPlanner.Terminal {
        var terminal = idle(surface)
        terminal.promptSince = nil
        terminal.commandSince = terminal.lastOutput
        return terminal
    }

    @Test func anIdleAgentWithARecordedSessionFreesAndResumesOnShow() {
        let plan = WorkspaceFreeingPlanner().plan([Self.agent("a1", .resumable)], policy: Self.on, now: Self.now)
        #expect(plan.due == ["a1"])
    }

    @Test func aWorkingAgentOrAgentsOffKeepsTheTerminal() {
        var off = Self.on
        off.agents = false
        #expect(WorkspaceFreeingPlanner().plan([Self.agent("a1", .resumable)], policy: off, now: Self.now).due.isEmpty)
        #expect(WorkspaceFreeingPlanner().plan([Self.agent("a1", .working)], policy: Self.on, now: Self.now).due.isEmpty)
    }

    @Test func neverKeepsARunningCommandAndItsWorkspacesShells() {
        let terminals = [Self.running("dev"), Self.idle("shell"), Self.idle("other", workspace: "w2")]
        #expect(WorkspaceFreeingPlanner().plan(terminals, policy: Self.on, now: Self.now).due == ["other"])
    }

    @Test func relaunchFreesARunningCommandWithItsShell() {
        var relaunch = Self.on
        relaunch.runningCommands = .relaunch
        let plan = WorkspaceFreeingPlanner().plan([Self.running("dev"), Self.idle("shell")], policy: relaunch, now: Self.now)
        #expect(Set(plan.due) == ["dev", "shell"])
    }

    @Test func settingsParseTheAgentAndRunningCommandKeys() throws {
        #expect(WorkspaceHibernationSettings().freeingAgents == true)
        #expect(WorkspaceHibernationSettings().freeingRunningCommands == .never)
        let json = #"{"workspaces":{"freeing":{"agents":false,"runningCommands":"relaunch"}}}"#
        let snapshot = CmuxConfigSnapshot.parse(try JSONValue.parse(Data(json.utf8)), validDensities: [], validMetrics: [])
        let policy = WorkspaceFreeingPlanner.Policy(snapshot.workspaceHibernation)
        #expect(policy.agents == false && policy.runningCommands == .relaunch)
    }

    // MARK: Coordinator

    /// The App's owners and this Mac's daemon in one fake.
    final class Host: WorkspaceHibernationHost, WorkspaceTerminalFreeing {
        var residents: [WorkspaceHibernationResident]
        var shown: Set<String> = []
        var freeing = WorkspaceFreeingPlanner.Policy(enabled: true, idleMinutes: 1440)
        var terminals: [WorkspaceFreeingPlanner.Terminal] = []
        var parked: [String] = []
        var asked: [Set<String>] = []

        init(_ ids: [String]) { residents = ids.map { WorkspaceHibernationResident(workspace: $0) } }
        func hibernationResidents() -> [WorkspaceHibernationResident] { residents }
        func hibernationShownWorkspaces() -> Set<String> { shown }
        func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy {
            var policy = WorkspaceHibernationPlanner.Policy(enabled: true, idleMinutes: 60)
            policy.freeing = freeing
            return policy
        }
        func hibernate(workspace: String) { residents.removeAll { $0.workspace == workspace } }
        func terminals(in workspaces: Set<String>) -> [WorkspaceFreeingPlanner.Terminal] {
            asked.append(workspaces)
            return terminals.filter { workspaces.contains($0.workspace) }
        }
        func park(_ surfaces: [String]) {
            parked += surfaces
            terminals.removeAll { surfaces.contains($0.surface) }
        }
    }

    final class Deadline: WorkspaceHibernationDeadline, @unchecked Sendable { // test-only; touched on the main actor alone
        var isScheduled = false
        func schedule(after delay: Duration, _ action: @escaping @isolated(any) @Sendable () async -> Void) { isScheduled = true }
        func cancel() { isScheduled = false }
    }

    final class Clock {
        var now = WorkspaceFreeingTests.now
        func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
    }

    static func make(_ ids: [String]) -> (WorkspaceHibernation, Host, Clock) {
        let host = Host(ids)
        let clock = Clock()
        let defaults = UserDefaults(suiteName: "WorkspaceFreeingTests.\(UUID().uuidString)")!
        let hibernation = WorkspaceHibernation(host: host, keepAwake: WorkspaceKeepAwakeStore(defaults: defaults), deadline: Deadline(),
                                               now: { clock.now }, terminals: host)
        return (hibernation, host, clock)
    }

    /// A shell whose prompt and output are as old as the start: idle since then.
    static func terminal(_ surface: String, in workspace: String) -> WorkspaceFreeingPlanner.Terminal {
        WorkspaceFreeingPlanner.Terminal(surface: surface, workspace: workspace, workspaceLastActive: nil, hibernated: false,
                                         promptSince: now, lastOutput: now)
    }

    @Test func aHibernatedWorkspacesIdleShellFreesAfterADayOnlyOnce() {
        let (hibernation, host, clock) = Self.make(["a", "b"])
        host.terminals = [Self.terminal("a1", in: "a"), Self.terminal("b1", in: "b")]
        host.shown = ["b"]
        hibernation.noteShown(["b"])
        hibernation.pass() // first sight
        clock.advance(hours: 2)
        hibernation.pass() // a hibernates
        #expect(hibernation.isHibernated("a"))
        #expect(host.parked.isEmpty)
        clock.advance(hours: 23)
        hibernation.pass()
        #expect(host.parked == ["a1"], "b is shown: its shell keeps running")
        hibernation.pass()
        #expect(host.parked == ["a1"])
        #expect(hibernation.freedCount == 1)
    }

    @Test func keepAwakeAndOffKeepTheShell() {
        let (hibernation, host, clock) = Self.make(["a", "b"])
        host.terminals = [Self.terminal("a1", in: "a")]
        hibernation.pass()
        clock.advance(hours: 2)
        hibernation.pass()
        hibernation.toggleKeepAwake("a")
        clock.advance(hours: 30)
        hibernation.pass()
        #expect(host.parked.isEmpty)
        hibernation.toggleKeepAwake("a")
        host.freeing.enabled = false
        hibernation.pass()
        #expect(host.parked.isEmpty)
        #expect(host.asked.allSatisfy { !$0.isEmpty })
    }

    @Test func showingTheWorkspaceAgainRestartsItsClock() {
        let (hibernation, host, clock) = Self.make(["a", "b"])
        host.terminals = [Self.terminal("a1", in: "a")]
        hibernation.pass()
        clock.advance(hours: 2)
        hibernation.pass() // a hibernates
        clock.advance(hours: 20)
        host.residents.append(WorkspaceHibernationResident(workspace: "a"))
        host.shown = ["a"]
        hibernation.noteShown(["a"]) // shown: awake
        host.shown = ["b"]
        hibernation.noteShown(["b"])
        clock.advance(hours: 2)
        hibernation.pass() // hibernates again
        clock.advance(hours: 10)
        hibernation.pass()
        #expect(host.parked.isEmpty, "used 12 hours ago: not a day yet")
    }
}
