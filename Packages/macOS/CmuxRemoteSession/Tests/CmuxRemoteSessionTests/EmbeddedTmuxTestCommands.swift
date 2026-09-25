import CmuxFoundation
import Foundation

/// An injected management connection whose completion is controlled by the test.
actor EmbeddedTmuxTestCommands: CommandRunning {
    private(set) var calls: [[String]] = []
    private let result: CommandResult?
    private var completion: CheckedContinuation<CommandResult, Never>?
    private let started: AsyncStream<Void>
    private let didStart: AsyncStream<Void>.Continuation

    init(stdout: String? = "%17\n", status: Int32 = 0, suspended: Bool = false) {
        result = suspended ? nil : CommandResult(
            stdout: stdout, stderr: nil, exitStatus: status,
            timedOut: false, executionError: nil
        )
        (started, didStart) = AsyncStream<Void>.makeStream()
    }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        calls.append([executable] + arguments)
        if let result {
            didStart.yield(())
            return result
        }
        return await withCheckedContinuation { continuation in
            completion = continuation
            didStart.yield(())
        }
    }

    func waitForStart() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }

    func complete() {
        completion?.resume(returning: CommandResult(
            stdout: "%18\n", stderr: nil, exitStatus: 0,
            timedOut: false, executionError: nil
        ))
        completion = nil
    }
}
