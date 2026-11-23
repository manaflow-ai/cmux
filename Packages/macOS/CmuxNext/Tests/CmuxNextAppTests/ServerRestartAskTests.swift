import CmuxUpdater
import Testing
@testable import CmuxNextUpdater

/// A server restart the person starts asks at most once (design audit 2026-11-18 #20; Leo: "All 4 do
/// em these didn't need my addl input"). Before, every restart showed the toast and then a confirm,
/// even when nothing would be lost. Now the click restarts at once when nothing is lost, and the one
/// confirm shows only when something is: an agent mid-turn, a running command, an unconfirmed
/// daemon mirror, or a restart that ends running agents.
@MainActor
struct ServerRestartAskTests {
    private struct Run {
        var prompts = 0
        var restarts = 0
        var declines = 0
    }

    private static func notice(_ kind: ServerKind = .cmuxTUI, keepsWork: Bool = true) -> ServerUpdateNotice {
        ServerUpdateNotice(kind: kind, host: .local, serverBuild: "old1234", missingCapabilities: [], gainedFeatures: [],
                           impact: ServerRestartImpact(kind: kind, keepsWork: keepsWork))
    }

    /// One restart request, the way ``ServerUpdatePresenter`` runs it, counting the prompts it shows.
    private static func run(_ notice: ServerUpdateNotice, _ blockers: UpdateRelaunchBlockers, byPerson: Bool = true, answer: Bool = true) -> Run {
        var run = Run()
        ServerRestartAsk.run(notice, blockers: blockers, byPerson: byPerson, ask: { spec, answered in
            #expect(spec == notice.confirmSpec)
            run.prompts += 1
            answered(answer)
        }, restart: { run.restarts += 1 }, declined: { run.declines += 1 })
        return run
    }

    @Test func withNothingToLoseTheRestartShowsNoPrompt() {
        let run = Self.run(Self.notice(), .empty)
        #expect(run.prompts == 0)
        #expect(run.restarts == 1)
        #expect(ServerRestartAsk.prompt(for: Self.notice(), blockers: .empty, byPerson: true) == nil)
    }

    /// Recent typing alone is not something a restart loses: the click itself is input.
    @Test func recentInputAloneDoesNotAsk() {
        let run = Self.run(Self.notice(), UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0, userInputActive: true))
        #expect(run.prompts == 0)
        #expect(run.restarts == 1)
    }

    @Test func aRunningTurnAsksExactlyOnce() {
        let busy = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        let yes = Self.run(Self.notice(), busy)
        #expect(yes.prompts == 1)
        #expect(yes.restarts == 1)
        let no = Self.run(Self.notice(), busy, answer: false)
        #expect(no.prompts == 1)
        #expect(no.restarts == 0)
        #expect(no.declines == 1)
    }

    @Test func aRunningCommandOrAnUnconfirmedMirrorAsksOnce() {
        #expect(Self.run(Self.notice(), UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 2)).prompts == 1)
        #expect(Self.run(Self.notice(), .daemonUnavailable).prompts == 1)
    }

    /// An agent, script, page or control-socket run always asks: only a person's click is the ask.
    @Test func aRunNoPersonStartedAlwaysAsks() {
        let run = Self.run(Self.notice(), .empty, byPerson: false)
        #expect(run.prompts == 1)
        #expect(run.restarts == 1)
    }

    /// A restart that ends running agents always asks, even with nothing mid-turn.
    @Test func aRestartThatEndsRunningAgentsAlwaysAsks() {
        let run = Self.run(Self.notice(.acpmux, keepsWork: false), .empty)
        #expect(run.prompts == 1)
        #expect(run.restarts == 1)
    }
}
