import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The completion shell's stdout is read with `readReady()` (cmuxterm-hq#4753): every chunk is kept,
/// and the end of the pipe closes the read so the answer comes once the shell exits.
struct AgentPaneShellCompletionProcessTests {
    @Test func theShellsWholeOutputComesBackAtTheEndOfThePipe() async throws {
        // More than one pipe buffer, written in pieces, so the handler runs several times.
        let script = "printf 'candidate\\n'; /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' x"
        let output = try await CompletionProcess.run(path: "/bin/sh", arguments: ["/bin/sh", "-c", script], environment: [:],
                                                     folder: NSTemporaryDirectory(), timeout: .seconds(20))
        #expect(output.count == "candidate\n".utf8.count + 200_000)
        #expect(output.starts(with: Data("candidate\n".utf8)))
    }
}
