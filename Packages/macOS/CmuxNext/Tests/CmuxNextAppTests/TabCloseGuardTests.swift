@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// A tab close asks once, and only while a closing terminal is doing work
/// (#17501, as classic #17430): an agent at work gets its own question and
/// toggle, any other program the tab question. Idle closes never ask.
@MainActor
struct TabCloseGuardTests {
    @Test func idleTerminalsNeverAsk() {
        #expect(TabCloseGuard.warning(agents: [], programs: [], warnTab: true, warnAgent: true) == nil)
    }

    @Test func aRunningProgramAsksUnderTheTabToggle() {
        #expect(TabCloseGuard.warning(agents: [], programs: ["npm", "vim"], warnTab: true, warnAgent: true) == .programs(["npm", "vim"]))
        #expect(TabCloseGuard.warning(agents: [], programs: ["vim"], warnTab: false, warnAgent: true) == nil)
    }

    /// The agent question is the only one shown, even beside other programs.
    @Test func aWorkingAgentAsksUnderItsOwnToggle() {
        #expect(TabCloseGuard.warning(agents: ["Claude"], programs: ["vim"], warnTab: true, warnAgent: true) == .agent("Claude"))
        #expect(TabCloseGuard.warning(agents: ["Claude"], programs: [], warnTab: true, warnAgent: false) == nil)
        #expect(TabCloseGuard.warning(agents: ["Claude"], programs: ["vim"], warnTab: true, warnAgent: false) == .programs(["vim"]))
    }

    @Test func agentNamesReadAsNames() {
        #expect(TabCloseGuard.displayName("claude") == "Claude")
        #expect(TabCloseGuard.displayName("codex") == "Codex")
        #expect(TabCloseGuard.displayName(nil) == ConfirmationStrings.theAgent)
    }

    /// One dialog: Return closes, Escape cancels, and "Don't ask again"
    /// turns off the toggle that asked.
    @Test func theQuestionHasDontAskAgainForItsToggle() {
        let prompt = DestructiveConfirmation.Prompt(title: "Close “zsh”?", body: ConfirmationStrings.stillRunning("vim"),
                                                    button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingTabPath)
        let spec = DestructiveConfirmation.spec(prompt)
        #expect(spec.fields == [.check(id: DestructiveConfirmation.suppressID, title: QuitStrings.dontAskAgain, on: false)])
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == .press(DestructiveConfirmation.confirmID))
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("cancel"))
        let plain = DestructiveConfirmation.spec(.init(title: "Delete?", body: "x", button: "Delete"))
        #expect(plain.fields.isEmpty, "other confirmations keep no check box")
    }

    @Test func agentAndProgramBodiesNameWhatStops() {
        #expect(ConfirmationStrings.agentStillWorking("Claude") == "Claude is still working.")
        #expect(ConfirmationStrings.stillRunning("vim, npm") == "Still running: vim, npm.")
        #expect(ConfirmationStrings.closeTabsTitle(3) == "Close 3 tabs?")
    }
}
