import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextPhone

/// Records every argv and answers from canned results keyed by the argv
/// prefix. Started commands write their output file when interrupted, like
/// `simctl io recordVideo` finalizing on SIGINT.
final class FakePhoneRunner: PhoneCommandRunning {
    struct Started: Sendable {
        let arguments: [String]
        let command: FakeRunning
    }

    private let state = Mutex<(runs: [[String]], stdins: [Data], started: [Started], answers: [([String], PhoneCommandResult)])>(([], [], [], []))

    func answer(_ prefix: [String], _ result: PhoneCommandResult) {
        state.withLock { $0.answers.append((prefix, result)) }
    }

    var runs: [[String]] { state.withLock { $0.runs } }
    var stdins: [Data] { state.withLock { $0.stdins } }
    var started: [Started] { state.withLock { $0.started } }

    func run(_ arguments: [String], stdin: Data?, deadline: Duration) async throws -> PhoneCommandResult {
        let answer = state.withLock { state -> PhoneCommandResult? in
            state.runs.append(arguments)
            if let stdin { state.stdins.append(stdin) }
            return state.answers.last(where: { arguments.starts(with: $0.0) })?.1
        }
        // Screenshots write their file, like the real tools.
        if let index = arguments.firstIndex(of: "screenshot"), answer?.status ?? 0 == 0 {
            let path = arguments.first(where: { $0.hasSuffix(".png") }) ?? arguments[index + 1]
            FileManager.default.createFile(atPath: path, contents: Data("png".utf8))
        }
        return answer ?? PhoneCommandResult(status: 0)
    }

    func start(_ arguments: [String], stdoutFile: URL?) async throws -> any PhoneRunningCommand {
        let output = stdoutFile ?? arguments.last.map { URL(fileURLWithPath: $0) }
        let command = FakeRunning(output: output)
        state.withLock { $0.started.append(Started(arguments: arguments, command: command)) }
        return command
    }
}

final class FakeRunning: PhoneRunningCommand {
    let output: URL?
    private let state = Mutex<(interrupted: Bool, exited: Bool)>((false, false))
    init(output: URL?) { self.output = output }

    var interrupted: Bool { state.withLock { $0.interrupted } }

    func interrupt() async {
        state.withLock { $0.interrupted = true }
        if let output { FileManager.default.createFile(atPath: output.path, contents: Data("data".utf8)) }
    }

    func waitForExit(deadline: Duration) async -> Int32 {
        state.withLock { $0.exited = true }
        return interrupted ? 0 : 130
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
