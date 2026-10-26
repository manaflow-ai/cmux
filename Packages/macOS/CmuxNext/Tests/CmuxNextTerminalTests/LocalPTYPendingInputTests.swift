import CmuxNextTerminal
import Foundation
import Testing

/// Input larger than the PTY's input queue waits in the local PTY's pending input (a checked Sendable since
/// p10-stability-052) and reaches the program whole and in order once it reads: the write source resumes
/// the flush each time the queue has room.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LocalPTYPendingInputTests {
    @Test func inputLargerThanThePTYQueueArrivesWhole() async throws {
        // cat in canonical mode: the line discipline echoes each line and cat writes it back.
        let io = try LocalPTYTerminalIO(shell: "/bin/cat", workingDirectory: "/")
        defer { io.terminate() }
        let lines = 2048
        let line = String(repeating: "a", count: 99) + "\n"
        let sent = lines * 99
        await io.write(Data(String(repeating: line, count: lines).utf8))

        var received = 0
        for await event in io.events {
            guard case .output(let data) = event else { continue }
            received += data.reduce(0) { $0 + ($1 == UInt8(ascii: "a") ? 1 : 0) }
            if received >= 2 * sent { break }
        }
        #expect(received == 2 * sent, "the echo and cat's copy should each carry every byte written")
    }
}
