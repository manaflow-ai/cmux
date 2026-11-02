@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextSettings
import Testing

/// 2026-10-31 18:46: with `app.quitBehavior: "end-everything"` set, one Cmd-Q
/// typed mid-sentence quit at once (no dialog) and closed all 900 local
/// workspaces (796 agent chats, 490 terminals), one by one over two minutes,
/// while the window stayed up. A remembered choice must never delete
/// workspaces without a confirmation: an interactive quit asks (Return keeps,
/// Escape cancels, End Everything has no key), and a quit that cannot ask ends
/// the sessions but keeps the workspaces. Only an explicit End Everything
/// (the File menu item, `cmux app quit --end-everything`) deletes them as is.
@MainActor struct QuitEndEverythingGuardTests {
    private static let facts = QuitFacts(terminals: 490, programs: [QuitProgram(name: "claude", cpuNanos: 9)],
                                         incognitoPrograms: [], remoteSessions: false)

    @Test func aRememberedEndEverythingAsksOnCmdQ() {
        let decision = QuitPolicy.decide(.interactive, behavior: .endEverything, facts: Self.facts)
        guard case .ask(let prompt) = decision else {
            Issue.record("Cmd-Q with end-everything remembered quit at once: \(decision)")
            return
        }
        #expect(prompt.confirmsEndEverything)
        #expect(prompt.defaultChoice == .keep)
        let content = QuitAlertContent.main(prompt)
        // Return keeps (the first button is the primary one), Escape cancels.
        #expect(content.buttons == [.keep, .cancel, .endEverything])
        #expect(!content.showsSuppression)
        #expect(content.title == QuitStrings.endEverythingTitle)
    }

    @Test func confirmingTheDialogEndsEverything() {
        let prompt = QuitPrompt(terminals: 1, runningPrograms: 0, busiest: [], incognitoPrograms: [],
                                remoteSessions: false, offersSessionChoice: true, defaultChoice: .keep,
                                confirmsEndEverything: true)
        let alert = QuitAlert(prompt: prompt) { _ in }
        #expect(alert.buttons.map(\.id).last == QuitAlertContent.Button.keep.rawValue)
        #expect(alert.buttons.first { $0.id == QuitAlertContent.Button.endEverything.rawValue }?.role == .destructive)
    }

    @Test func aQuitThatCannotAskKeepsTheWorkspaces() {
        #expect(QuitPolicy.decide(.scripted, behavior: .endEverything, facts: .none) == .quit(.endKeepLayout))
        // After the unsaved-changes question (#17501: one dialog per quit).
        #expect(QuitPolicy.decide(.interactive, behavior: .endEverything, facts: Self.facts, alreadyAsked: true)
            == .quit(.endKeepLayout))
    }

    @Test func anExplicitEndEverythingStillRunsAsAsked() {
        #expect(QuitPolicy.decide(.explicit(.endEverything), behavior: .keep, facts: .none) == .quit(.endEverything))
        #expect(QuitPolicy.decide(.explicit(.endEverything), behavior: .endEverything, facts: .none) == .quit(.endEverything))
    }

    @Test func theOtherRememberedChoicesStillQuitAtOnce() {
        #expect(QuitPolicy.decide(.interactive, behavior: .endKeepLayout, facts: Self.facts) == .quit(.endKeepLayout))
        #expect(QuitPolicy.decide(.interactive, behavior: .keep, facts: Self.facts) == .quit(.keep))
        #expect(QuitPolicy.decide(.powerOff, behavior: .endEverything, facts: Self.facts) == .quit(.keep))
        #expect(QuitPolicy.decide(.signal, behavior: .endEverything, facts: Self.facts) == .quit(.keep))
        // Ask is not a remembered choice: with local terminals a person's quit asks how to quit, Keep the
        // default (QUIT P0, #29984: Lawrence 2026-11-01 "cmd q needs to prompt for what type of quit").
        guard case .ask(let prompt) = QuitPolicy.decide(.interactive, behavior: .ask, facts: Self.facts) else {
            Issue.record("Ask with local terminals quit with no question")
            return
        }
        #expect(prompt.offersSessionChoice && prompt.defaultChoice == .keep && !prompt.confirmsEndEverything)
    }
}
