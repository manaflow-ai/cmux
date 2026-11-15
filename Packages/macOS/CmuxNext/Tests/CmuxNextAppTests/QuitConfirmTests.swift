@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// "Quit cmux?" (Lawrence 2026-11-10: Cmd-Q with End Sessions remembered ended every agent and terminal with no
/// question). A person's quit that ends the sessions asks while an agent works or a terminal is open; a quit that
/// loses nothing, or that nobody is there to answer, never asks.
@MainActor
struct QuitConfirmTests {
    static let busy = QuitLosses(agents: 3, terminals: 106)

    @Test func confirmQuitIsOnByDefault() {
        #expect(CmuxConfigSnapshot.confirmQuitDefault)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).confirmQuit)
        let off = JSONValue.object(["app": .object(["confirmQuit": .bool(false)])])
        #expect(!CmuxConfigSnapshot.parse(off, validDensities: [], validMetrics: []).confirmQuit)
    }

    @Test(arguments: [QuitSessionsChoice.endKeepLayout, .endEverything])
    func cmdQThatEndsRunningWorkAsks(choice: QuitSessionsChoice) {
        #expect(QuitRules.confirms(.interactive, choice: choice, setting: true, losses: Self.busy))
        #expect(QuitRules.confirms(.interactive, choice: choice, setting: true, losses: QuitLosses(agents: 1, terminals: 0)))
        #expect(QuitRules.confirms(.interactive, choice: choice, setting: true, losses: QuitLosses(agents: 0, terminals: 1)))
    }

    /// The accident of 2026-11-10 itself: Cmd-Q, End Sessions Keep Layout remembered, agents at work.
    @Test func theRememberedEndChoiceNoLongerQuitsUnasked() {
        let choice = QuitPolicy.decide(.interactive, behavior: .endKeepLayout)
        #expect(QuitRules.confirms(.interactive, choice: choice, setting: true, losses: Self.busy))
    }

    @Test func aQuitThatKeepsTheSessionsNeverAsks() {
        #expect(!QuitRules.confirms(.interactive, choice: .keep, setting: true, losses: Self.busy))
    }

    @Test func nothingToLoseNeverAsks() {
        #expect(!QuitRules.confirms(.interactive, choice: .endKeepLayout, setting: true, losses: QuitLosses(agents: 0, terminals: 0)))
    }

    @Test func theSettingTurnsTheQuestionOff() {
        #expect(!QuitRules.confirms(.interactive, choice: .endKeepLayout, setting: false, losses: Self.busy))
    }

    /// The update relaunch quits as explicit keep sessions; the "Quit and End…" items, scripts, signals and power
    /// off run as asked.
    @Test(arguments: [QuitOrigin.explicit(.keep), .explicit(.endKeepLayout), .explicit(.endEverything), .scripted, .signal, .powerOff])
    func onlyAPersonsPlainQuitAsks(origin: QuitOrigin) {
        #expect(!QuitRules.confirms(origin, choice: .endKeepLayout, setting: true, losses: Self.busy))
    }

    @Test func theQuestionNamesTheCountsAndReturnQuits() {
        let text = QuitConfirmText(Self.busy)
        #expect(text.lines.count == 2)
        #expect(text.lines[0].contains("3"))
        #expect(text.lines[1].contains("106"))
        #expect(QuitConfirmText(QuitLosses(agents: 0, terminals: 2)).lines.count == 1)
        let spec = DestructiveConfirmation.spec(.init(title: text.title, body: text.lines.joined(separator: " "), button: text.quit,
                                                      suppresses: CmuxConfigSnapshot.confirmQuitPath))
        #expect(spec.buttons.first { $0.role == .default }?.id == DestructiveConfirmation.confirmID)
        #expect(spec.buttons.contains { $0.role == .cancel })
    }
}
