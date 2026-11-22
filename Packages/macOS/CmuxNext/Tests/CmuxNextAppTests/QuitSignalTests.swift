@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Coordinator decision 2026-10-02: dev tooling (scripts/reload.sh,
/// reloads.sh, launch-tagged-automation.sh, scripts/lib/stop-app-instances.sh)
/// quits tagged apps with SIGTERM and must never hang on the quit alert.
/// SIGTERM is "Quit, keep sessions": never an alert, never ends a terminal.
@MainActor
struct QuitSignalTests {
    static let busy = QuitFacts(terminals: 3, programs: [QuitProgram(name: "vim", cpuNanos: 1)],
                                incognitoPrograms: ["npm"], remoteSessions: true)

    @Test func sigtermNeverAsksAndKeepsTheSessions() {
        for behavior in QuitBehavior.allCases {
            #expect(QuitPolicy.decide(.signal, behavior: behavior, facts: Self.busy) == .quit(.keep), "\(behavior)")
        }
        #expect(!QuitPolicy.needsFacts(.signal))
    }

    /// SIGTERM while the alert is open answers it as Quit, keep sessions,
    /// even when a remembered End is its default button.
    @Test func sigtermAnswersAnOpenAlertWithKeep() {
        let prompt = QuitPrompt(terminals: 3, runningPrograms: 1, busiest: ["vim"], incognitoPrograms: ["npm"],
                                remoteSessions: false, offersSessionChoice: false, defaultChoice: .endEverything)
        var answers: [QuitAlert.Answer] = []
        let alert = QuitAlert(prompt: prompt) { answers.append($0) }
        alert.answerKeepingSessions()
        alert.answerKeepingSessions()
        #expect(answers == [.quit(.keep, remember: false)])
    }
}
