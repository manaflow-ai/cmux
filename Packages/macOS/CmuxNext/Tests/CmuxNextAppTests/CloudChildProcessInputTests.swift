import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudChildProcessInputTests {
    @Test func boundedInitializerInputStillReachesTheChildAndCloses() async throws {
        let process = ChildProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                   environment: [:], input: Data("synthetic-startup\n".utf8))
        try process.start()
        defer { process.terminateProcessOnly() }
        let line: String = try await process.firstLine(within: .seconds(5), label: "stdin fixture") { $0 }
        #expect(line == "synthetic-startup")
        #expect(await process.waitForExit() == 0)
    }

    @Test func oversizedInitializerInputIsRejectedBeforeLaunch() throws {
        let process = ChildProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                   environment: [:], input: Data(repeating: 0x61, count: 16 * 1024 + 1))
        #expect(throws: CocoaError.self) { try process.start() }
        #expect(process.pid == nil)
        #expect(!process.isRunning)
    }
}
