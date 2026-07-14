import Foundation
@testable import CmuxSimulator

/// A fake `simctl` seam: replays canned responses and records every invocation.
actor RecordingSimctlRunner: SimctlCommandRunning {
    /// One canned response: the first not-yet-consumed `Response` whose
    /// `matching` prefix equals the invocation's leading arguments is used,
    /// then consumed (so staged scenarios can return different data for
    /// repeated invocations of the same command).
    struct Response: Sendable {
        let matching: [String]
        let result: Result<Data, SimctlCommandFailure>

        init(matching: [String], data: Data) {
            self.matching = matching
            self.result = .success(data)
        }

        init(matching: [String], failure: SimctlCommandFailure) {
            self.matching = matching
            self.result = .failure(failure)
        }
    }

    private var responses: [Response]
    private(set) var recordedInvocations: [[String]] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    /// Appends a response after construction (for staged scenarios).
    func addResponse(_ response: Response) {
        responses.append(response)
    }

    @discardableResult
    func run(_ arguments: [String]) async throws -> Data {
        recordedInvocations.append(arguments)
        guard let index = responses.firstIndex(where: { arguments.starts(with: $0.matching) }) else {
            throw SimctlCommandFailure(
                arguments: arguments,
                exitCode: 64,
                standardErrorText: "RecordingSimctlRunner has no response for \(arguments)"
            )
        }
        let response = responses.remove(at: index)
        switch response.result {
        case .success(let data):
            return data
        case .failure(let failure):
            throw failure
        }
    }
}
