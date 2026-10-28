import CmuxNextDaemon
import CmuxNextDaemonService
import Testing
@testable import CmuxNextApp

/// The quit's last steps (plans/cmux-next/chrome-parity/p02-threads.md, task 012): the last save, then the
/// deadline, then the background lanes start to drain alongside the engine stop, and the quit waits for their
/// block-shutdown saves once, after the engines stopped, so the drain takes none of Chromium's budget.
@MainActor
struct QuitCompletionDrainTests {
    /// The steps that ran, in order.
    final class Log {
        var steps: [String] = []
    }

    static func steps(_ log: Log, failures: [EndSessionsFailure] = []) -> QuitSteps {
        QuitSteps(
            remember: { _ in log.steps.append("remember") },
            prepareWindows: { log.steps.append("prepareWindows") },
            endLocalSessions: { _ in
                log.steps.append("endLocalSessions")
                return failures
            },
            confirmFailures: { _ in
                // The first failure is retried once, then the quit goes on.
                let retried = log.steps.contains("confirm")
                log.steps.append("confirm")
                return retried ? .quitAnyway : .retry
            },
            endLocalAgents: {
                log.steps.append("endLocalAgents")
                return []
            },
            lastSave: { log.steps.append("lastSave") },
            armDeadline: { log.steps.append("armDeadline") },
            beginDrain: { log.steps.append("beginDrain") },
            stopBrowserEngines: { log.steps.append("stopBrowserEngines") },
            finishDrain: { log.steps.append("finishDrain") }
        )
    }

    static let tail = ["lastSave", "armDeadline", "beginDrain", "stopBrowserEngines", "finishDrain"]

    @Test func keepDrainsOnceAfterTheLastSaveInsideTheDeadline() async {
        let log = Log()
        await QuitCompletion.run(.keep, remember: true, Self.steps(log))
        #expect(log.steps == ["remember", "prepareWindows"] + Self.tail)
    }

    @Test func anEndWithARetryStillDrainsOnceAtTheEnd() async {
        let log = Log()
        let failure = EndSessionsFailure(step: .shutdownDaemon, message: "busy")
        await QuitCompletion.run(.endKeepLayout, remember: false, Self.steps(log, failures: [failure]))
        let end = ["endLocalAgents", "endLocalSessions", "confirm"]
        #expect(log.steps == ["prepareWindows"] + end + end + Self.tail)
        #expect(log.steps.filter { $0 == "beginDrain" }.count == 1)
        #expect(log.steps.filter { $0 == "finishDrain" }.count == 1)
    }
}
