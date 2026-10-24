@testable import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import Testing

/// A report reply runs its acpmux process off the main thread (plans/cmux-next/main-thread-budget.md)
/// with the acpmux environment resolved once at startup, and it counts as sent only when acpmux
/// took it (exit status 0). Before, `Process.run()` ran on the main thread inside the view's
/// callback after an environment resolve with a code-signature check, and a refused or hung send
/// still cleared the draft.
@MainActor @Suite struct AcpmuxReplySenderTests {
    nonisolated private final class Recorder: ProcessLaunching {
        let status: Int32?
        let calls = Mutex<[(executable: URL, arguments: [String], environment: [String: String], onMain: Bool)]>([])

        init(status: Int32?) {
            self.status = status
        }

        func run(_ executable: URL, arguments: [String], environment: [String: String]) async -> Int32? {
            record(executable, arguments, environment)
            return status
        }

        /// Synchronous, so it can ask which thread it runs on.
        private func record(_ executable: URL, _ arguments: [String], _ environment: [String: String]) {
            calls.withLock { $0.append((executable, arguments, environment, Thread.isMainThread)) }
        }
    }

    private func environment() -> AcpmuxEnvironment {
        let directory = FileManager.default.temporaryDirectory
        return AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                 socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: ["ACPMUX_HOME": "/x"])
    }

    @Test func aReplyRunsAcpmuxOffTheMainThreadWithTheGivenEnvironment() async {
        let recorder = Recorder(status: 0)
        let replies = AcpmuxReplySender(launcher: recorder, baseEnvironment: ["PATH": "/usr/bin", "ACPMUX_HOME": "/inherited"])
        let environment = environment()
        let sent = await replies.send(session: "s-1", text: "thanks", promptID: "p-1", environment: environment)
        #expect(sent)
        let calls = recorder.calls.withLock { $0 }
        #expect(calls.map(\.arguments) == [["send", "--no-wait", "--no-steer", "--prompt-id", "p-1", "--", "s-1", "thanks"]])
        #expect(calls.first?.executable == environment.executable)
        #expect(calls.first?.environment == ["PATH": "/usr/bin", "ACPMUX_HOME": "/x"], "acpmux's own variables must win over the inherited ones")
        #expect(calls.first?.onMain == false, "the process must never run on the main thread")
    }

    @Test(arguments: [Int32?.some(1), Int32?.some(70), nil])
    func aRefusedFailedOrTimedOutSendIsNotSent(status: Int32?) async {
        let replies = AcpmuxReplySender(launcher: Recorder(status: status), baseEnvironment: [:])
        let sent = await replies.send(session: "s-1", text: "thanks", promptID: "p-1", environment: environment())
        #expect(!sent, "a send that acpmux did not take (status \(String(describing: status))) counted as sent")
    }

    @Test func aReplyWithoutASessionOrAcpmuxRunsNothing() async {
        let recorder = Recorder(status: 0)
        let replies = AcpmuxReplySender(launcher: recorder, baseEnvironment: [:])
        let noSession = await replies.send(session: "", text: "x", promptID: "p-1", environment: environment())
        let noPromptID = await replies.send(session: "s-1", text: "x", promptID: "", environment: environment())
        let noAcpmux = await replies.send(session: "s-1", text: "x", promptID: "p-1", environment: nil)
        #expect(!noSession)
        #expect(!noPromptID)
        #expect(!noAcpmux)
        #expect(recorder.calls.withLock { $0 }.isEmpty)
    }

    /// A reply that looks like a flag is the message: every flag comes before `--`, and the
    /// session and the text after it, so acpmux's parser never reads the text as an option.
    /// Before, the text came before the flags with no `--`: "- fix the test first" was an
    /// unknown argument and "--quiet" changed the command.
    @Test(arguments: ["- fix the test first", "--quiet", "-n 2", "--prompt-id other"])
    func aReplyThatLooksLikeAFlagIsSentAfterTheEndOfTheOptions(text: String) async throws {
        let recorder = Recorder(status: 0)
        let replies = AcpmuxReplySender(launcher: recorder, baseEnvironment: [:])
        #expect(await replies.send(session: "s-1", text: text, promptID: "p-1", environment: environment()))
        let arguments = try #require(recorder.calls.withLock { $0 }.first?.arguments)
        let end = try #require(arguments.firstIndex(of: "--"), "no -- ends the options")
        #expect(Array(arguments[(end + 1)...]) == ["s-1", text])
        #expect(arguments[..<end].allSatisfy { $0 == "send" || $0 == "p-1" || $0.hasPrefix("--") },
                "an option after the text: \(arguments)")
        #expect(Array(arguments[..<end].suffix(2)) == ["--prompt-id", "p-1"], "the reply's own id must be passed")
    }
}
