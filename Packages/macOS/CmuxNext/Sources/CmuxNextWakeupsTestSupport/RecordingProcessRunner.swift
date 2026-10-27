import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A ``ProcessRunning`` that starts no child: it records each request (its priority, so a test can assert the
/// child's QoS) and answers with `answer`.
///
/// ```swift
/// let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 0, exited: true, output: Data("{}".utf8)) }
/// _ = try await ChiefUsageTool(executable: tool, processes: processes).run(["usage"], muxHome: home)
/// #expect(processes.requests.first?.priority == .userVisible)
/// ```
public final class RecordingProcessRunner: ProcessRunning {
    private let recorded = Mutex<[ProcessRequest]>([])
    private let answer: @Sendable (ProcessRequest) async throws -> ProcessOutcome

    /// - Parameter answer: what each run returns or throws.
    public init(answer: @escaping @Sendable (ProcessRequest) async throws -> ProcessOutcome) {
        self.answer = answer
    }

    /// A runner whose every run exits 0 with no output.
    public convenience init() {
        self.init { _ in ProcessOutcome(status: 0, exited: true, output: Data()) }
    }

    /// Every request so far, in arrival order.
    public var requests: [ProcessRequest] { recorded.withLock { $0 } }

    public func outcome(of request: ProcessRequest) async throws -> ProcessOutcome {
        recorded.withLock { $0.append(request) }
        return try await answer(request)
    }
}
