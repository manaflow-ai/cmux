import Foundation

actor CmuxRunWorkingDirectoryProcessGate {
    typealias Outcome = CmuxRunWorkingDirectoryProcessOutcome

    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var didRequestTimeout = false

    func value() async -> Outcome {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func requestTimeout() -> Bool {
        guard outcome == nil, !didRequestTimeout else { return false }
        didRequestTimeout = true
        return true
    }

    func complete(status: Int32, output: Data) {
        guard outcome == nil else { return }
        let completedOutcome: Outcome = didRequestTimeout
            ? .timedOut
            : .completed(status: status, output: output)
        outcome = completedOutcome
        continuation?.resume(returning: completedOutcome)
        continuation = nil
    }
}
