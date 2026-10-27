@testable import CmuxNextTerminal
import Dispatch
import Foundation
import Testing

/// The local PTY write queue is on the key echo path, next to its read queue: a typed key goes through it to
/// the shell and the frame that shows the echo waits for it (threading-model.md, QoS table; Chromium gives
/// the threads input and display wait on the same class, base/threading/platform_thread_apple.mm).
/// SocketWriterQoSTests checks the daemon writer, the other queue of p02-threads-030.
@Suite(.serialized) struct LocalPTYQoSTests {
    @Test func theWriteQueueRunsAtUserInteractive() throws {
        let io = try LocalPTYTerminalIO(shell: "/bin/sh", workingDirectory: "/", environment: ["PS1": ""], installedTerminfo: false)
        defer { io.terminate() }

        #expect(io.writeQueueQoS == .userInteractive)
    }
}
