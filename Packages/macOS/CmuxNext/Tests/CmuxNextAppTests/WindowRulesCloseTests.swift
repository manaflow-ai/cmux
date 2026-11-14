@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWindowRules
import Testing

/// The close rules answer through the app FFI (cmux-window-rules `close`, whose own tests hold the cases): these check
/// the round trip, the facts the app sends and the answers it reads back.
@MainActor @Suite struct WindowRulesCloseTests {
    private func tab(_ kind: TabKind, url: String? = nil, surface: UInt64) -> TabModel {
        TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), kind: kind, title: "t", url: url))
    }

    @Test func oneIdleTerminalBesideABlankPageAsksWhatTheTerminalRuns() throws {
        let rules = WindowRules()
        let blank = tab(.browser, url: "about:blank", surface: 1), terminal = tab(.pty, surface: 2)
        let toast = try #require(rules.closeToast([blank, terminal].map { WindowRules.ClosingTab($0, agentAtWork: false) }), "the FFI did not answer")
        #expect(toast == .askTerminals([1]))
    }

    @Test func twoRealTabsShowTheToast() throws {
        let tabs = [tab(.browser, url: "https://a.test", surface: 1), tab(.pty, surface: 2)]
        #expect(WindowRules().closeToast(tabs.map { WindowRules.ClosingTab($0, agentAtWork: false) }) == .show)
    }

    @Test func aWorkingAgentIsTheQuestionAndItsNameReadsCapitalized() throws {
        let rules = WindowRules(), warnings = WindowRules.Warnings(warnTab: true, warnAgent: true)
        var facts = WindowRules.ClosingTab(tab(.pty, surface: 1), agentAtWork: true)
        facts.agent = "claude"
        let reads = try #require(rules.closeReads([facts, WindowRules.ClosingTab(tab(.pty, surface: 2), agentAtWork: false)], warnings).reads)
        #expect(reads == WindowRules.Reads(agents: ["Claude"], others: [1]))
        let (warning, answered) = rules.closeWarning(agents: reads.agents, answers: [.init(title: "zsh", answered: true, program: "vim")],
                                                     unansweredAsks: true, warnings)
        #expect(answered)
        #expect(warning == .agent("Claude"))
    }

    @Test func bothWarningsOffNeverAsk() {
        let (reads, answered) = WindowRules().closeReads([WindowRules.ClosingTab(tab(.pty, surface: 1), agentAtWork: true)],
                                                         .init(warnTab: false, warnAgent: false))
        #expect(answered)
        #expect(reads == nil)
    }
}
