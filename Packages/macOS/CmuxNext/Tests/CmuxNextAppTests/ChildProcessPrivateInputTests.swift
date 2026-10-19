import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct ChildProcessPrivateInputTests {
    @Test func aFullBoundedPipeReachesEOFWithoutBlockingTheCaller() async throws {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/wc"), arguments: ["-c"])
        try child.start(input: Data(repeating: 65, count: 16_384))
        let count = try await child.firstLine(within: .seconds(5), label: "stdin byte count") {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        #expect(count == 16_384)
        #expect(await child.waitForExit() == 0)
    }

    @Test func oversizedInputIsRejectedBeforeLaunching() {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        #expect(throws: (any Error).self) { try child.start(input: Data(repeating: 65, count: 16_385)) }
        #expect(child.pid == nil)
    }

    @Test func anEarlyChildExitCannotSignalTheParent() async throws {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        try child.start(input: Data(repeating: 65, count: 16_384))
        #expect(await child.waitForExit() == 0)
    }
}
