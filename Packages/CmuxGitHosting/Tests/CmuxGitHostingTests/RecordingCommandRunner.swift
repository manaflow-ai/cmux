import CmuxProcess
import Foundation

/// A test ``CommandRunning`` that returns canned output keyed by the full command
/// line and records every invocation for assertions.
actor RecordingCommandRunner: CommandRunning {
    struct Invocation: Sendable, Equatable {
        let executable: String
        let arguments: [String]
    }

    private let outputs: [String: String]
    private(set) var invocations: [Invocation] = []

    /// - Parameter outputs: Maps `"<executable> <args joined by space>"` to stdout.
    init(outputs: [String: String] = [:]) {
        self.outputs = outputs
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocations.append(Invocation(executable: executable, arguments: arguments))
        let key = ([executable] + arguments).joined(separator: " ")
        if let stdout = outputs[key] {
            return CommandResult(
                stdout: stdout,
                stderr: nil,
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        }
        return CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        )
    }
}

/// Extracts a request's query as `name=value` strings for order-independent assertions.
func queryPairs(of request: URLRequest) -> Set<String> {
    guard let url = request.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
        return []
    }
    return Set(items.map { "\($0.name)=\($0.value ?? "")" })
}
