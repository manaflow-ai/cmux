import CmuxAuthRuntime
import Foundation

/// Passed through tasks and explicit process/socket boundaries for one user operation.
struct CloudOperationContext: Sendable {
    /// Keep the task-local payload reference-sized for macOS 14's back-deployed
    /// `TaskLocal.withValue` implementation. Passing this larger value directly
    /// can violate the task allocator's LIFO invariant in optimized callers.
    private final class TaskLocalValue: Sendable {
        let context: CloudOperationContext?

        init(_ context: CloudOperationContext?) {
            self.context = context
        }
    }

    @TaskLocal private static var taskLocalValue: TaskLocalValue?

    static var current: CloudOperationContext? {
        taskLocalValue?.context
    }

    static func withCurrent<T>(
        _ context: CloudOperationContext?,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $taskLocalValue.withValue(
            TaskLocalValue(context),
            operation: operation,
            isolation: isolation
        )
    }

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
        return try await Self.withCurrent(child) {
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
