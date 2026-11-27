import CmuxNextBridge
@testable import CmuxNextDaemon
import Testing

/// An agent terminal has two reports of one agent: the hook roster (`tab.agent`, from the CLI's
/// hooks) and the program's own OSC 7501 record (`tab.programStatus`). When they disagree, the
/// newer one is the agent's state: a stale `working` in either source is no spinner.
///
/// The live case (user, Oct 30, NIGHTLY): a Codex TUI reports OSC 7501 `working` while a
/// background terminal runs and keeps it after its turn ends, while its Stop hook reported idle;
/// a Claude Code terminal's roster kept a `working` hook from three days before its newer OSC
/// 7501 `done`. Both rows showed a spinner.
@MainActor
struct StaleAgentWorkingSpinnerTests {
    func tab(agent: AgentStatus?, records: [ProgramStatusRecord]) -> TabModel {
        let tab = TabModel(TabSnapshot(surface: 1, terminalResourceID: "term_1"))
        tab.agent = agent
        tab.programStatus = records
        return tab
    }

    func spins(_ tab: TabModel) -> Bool {
        let mapping = StatusMapping(turns: AgentTurnStateStore(), seen: ProgramStatusSeenStore())
        return mapping.loading(tab).state.isLoading || mapping.isWorking(tabs: [tab])
    }

    @Test func aCodexTurnThatEndedWithBackgroundTerminalsIsNotWorking() {
        // OSC 7501 working at 21:50, Stop hook idle at 00:00.
        let tab = tab(agent: AgentStatus(surface: 1, state: .idle, source: "hook", agent: "codex", updatedAtMs: 1_793_343_621_294),
                      records: [ProgramStatusRecord(state: .working, app: "codex", updatedSeq: 90,
                                                    updatedAtMs: 1_793_335_800_542, sinceMs: 1_793_335_800_542)])
        #expect(!spins(tab), "a newer idle hook outranks an older OSC 7501 working")
    }

    @Test func aStaleWorkingHookYieldsToANewerProgramReport() {
        // Hook working Oct 27, OSC 7501 done Oct 30.
        let tab = tab(agent: AgentStatus(surface: 1, state: .working, source: "hook", agent: "claude", updatedAtMs: 1_793_164_462_671),
                      records: [ProgramStatusRecord(state: .idle, app: "claude-code", updatedSeq: 4694,
                                                    updatedAtMs: 1_793_396_754_164)])
        #expect(!spins(tab), "a newer OSC 7501 report outranks an older working hook")
    }

    @Test func aNewTurnStillSpinsFromEitherSource() {
        // The hook reports a new prompt after Codex's deduplicated working record: working.
        let hookNewer = tab(agent: AgentStatus(surface: 1, state: .working, source: "hook", agent: "codex", updatedAtMs: 2_000),
                            records: [ProgramStatusRecord(state: .idle, app: "codex", updatedAtMs: 1_000)])
        #expect(spins(hookNewer))
        // The program reports working after the last idle hook: working.
        let programNewer = tab(agent: AgentStatus(surface: 1, state: .idle, source: "hook", agent: "codex", updatedAtMs: 1_000),
                               records: [ProgramStatusRecord(state: .working, app: "codex", updatedAtMs: 2_000)])
        #expect(spins(programNewer))
        // A record from an older host, with no report time, still counts.
        let untimed = tab(agent: AgentStatus(surface: 1, state: .idle, source: "hook", agent: "codex", updatedAtMs: 1_000),
                          records: [ProgramStatusRecord(state: .working, app: "codex")])
        #expect(spins(untimed))
    }
}
