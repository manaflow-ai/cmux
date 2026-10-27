import CmuxNextCompat
@testable import CmuxNextTrace

/// The records a test's ``TraceRuntime`` stub writes, in order (`TraceRuntime(role:clock:stubRecorder:)` with
/// `{ log.append($0) }`). The design suites' trace tests share it.
nonisolated final class TraceRecordLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }

    func removeAll() { state.withLock { $0.removeAll() } }

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    var phases: [TraceRuntime.Phase] { records.map(\.phase) }
}
