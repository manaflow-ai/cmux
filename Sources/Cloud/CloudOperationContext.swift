import CmuxAuthRuntime
import Foundation

/// Passed through tasks and explicit process/socket boundaries for one user operation.
struct CloudOperationContext: Sendable {
    @TaskLocal static var current: CloudOperationContext?

    let recorder: CloudOperationRecorder
    let identity: AuthenticatedSessionIdentity?
    let operationID: UUID
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let operation: CloudOperationKind
    let phase: CloudOperationPhase
    let attempt: Int
    let startedAt: Date
    let clock: ContinuousClock.Instant
    let sourceFile: String
    let sourceLine: Int

    var traceparent: String { "00-\(traceID)-\(spanID)-01" }
    var environment: [String: String] {
        ["CMUX_CLOUD_OPERATION_ID": operationID.uuidString.lowercased(),
         "CMUX_CLOUD_TRACE_ID": traceID, "CMUX_CLOUD_PARENT_SPAN_ID": spanID]
    }

    func withPhase<T>(
        _ phase: CloudOperationPhase, attempt: Int = 0, file: StaticString = #fileID, line: UInt = #line,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let child = await recorder.beginChild(of: self, phase: phase, attempt: attempt, file: file, line: line)
        return try await Self.$current.withValue(child) {
            do {
                let value = try await work()
                await recorder.finish(child)
                return value
            } catch {
                await recorder.finish(child, error: error)
                throw error
            }
        }
    }

    static func phase<T>(
        _ phase: CloudOperationPhase, attempt: Int = 0, file: StaticString = #fileID, line: UInt = #line,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        if let current { return try await current.withPhase(phase, attempt: attempt, file: file, line: line, work) }
        return try await work()
    }
}
