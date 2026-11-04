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

@Suite struct CloudChildProcessStderrLogTests {
    @Test func stderrGoesToTheLogOwnerOnlyAndEachLaunchStartsItEmpty() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-stderr-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("link.log")
        for word in ["first", "second"] {
            let process = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", "echo out-\(word); echo err-\(word) >&2"],
                                       environment: [:], stderrLog: log)
            try process.start()
            #expect(await process.waitForExit() == 0)
            // The stderr pipe's last bytes may reach their handler after the exit: a deadline-bounded wait
            // on the log's own contents, which the tail also holds.
            let deadline = ContinuousClock.now + .seconds(5)
            while (try? String(contentsOf: log, encoding: .utf8)) != "err-\(word)\n", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try String(contentsOf: log, encoding: .utf8) == "err-\(word)\n")
            #expect(process.stderrText == "err-\(word)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
