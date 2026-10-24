import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import Testing

/// A report reply starts its acpmux process off the main thread (plans/cmux-next/main-thread-budget.md):
/// the Feed page's view only awaits the result. Before, `Process.run()` ran on the main thread
/// inside the view's callback.
@MainActor @Suite struct AcpmuxReplySenderTests {
    private final class Recorder: ProcessLaunching {
        let calls = Mutex<[(arguments: [String], onMain: Bool)]>([])
        nonisolated func launch(_ executable: URL, arguments: [String], environment: [String: String]) -> Bool {
            calls.withLock { $0.append((arguments, Thread.isMainThread)) }
            return true
        }
        nonisolated deinit {}
    }

    private func environment() -> AcpmuxEnvironment {
        let directory = FileManager.default.temporaryDirectory
        return AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                 socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: ["ACPMUX_HOME": "/x"])
    }

    @Test func aReplyStartsAcpmuxOffTheMainThread() async {
        let recorder = Recorder()
        let replies = AcpmuxReplySender(launcher: recorder)
        let sent = await replies.send(session: "s-1", text: "thanks", environment: environment())
        #expect(sent)
        let calls = recorder.calls.withLock { $0 }
        #expect(calls.map(\.arguments) == [["send", "s-1", "thanks", "--no-wait", "--no-steer"]])
        #expect(calls.first?.onMain == false, "the process launch must never run on the main thread")
    }

    @Test func aReplyWithoutASessionStartsNothing() async {
        let recorder = Recorder()
        let sent = await AcpmuxReplySender(launcher: recorder).send(session: "", text: "x", environment: environment())
        #expect(!sent)
        #expect(recorder.calls.withLock { $0 }.isEmpty)
    }
}
