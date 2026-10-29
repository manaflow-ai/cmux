import CmuxAuthRuntime
import CmuxFoundation
import Foundation

/// Passed through tasks and explicit process/socket boundaries for one user operation.
public struct CloudOperationContext: Sendable {
    // The context holds UUIDs and Dates, whose run-time size makes macOS 14's
    // back-deployed TaskLocal fallback abort; bind it by reference instead.
    @TaskLocal private static var boundContext: TaskLocalReference<CloudOperationContext>?

    public static var current: CloudOperationContext? {
        boundContext?.value
    }

    public static func withCurrent<T>(
        _ context: CloudOperationContext?,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $boundContext.withReferencedValue(context, isolation: isolation, operation: operation)
    }

    public let recorder: CloudOperationRecorder
    public let identity: AuthenticatedSessionIdentity?
    public let operationID: UUID
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let operation: CloudOperationKind
    public let phase: CloudOperationPhase
    public let attempt: Int
    public let startedAt: Date
    public let clock: ContinuousClock.Instant
    let sourceFile: String
    let sourceLine: Int

    public var traceparent: String { "00-\(traceID)-\(spanID)-01" }
    public var environment: [String: String] {
        ["CMUX_CLOUD_OPERATION_ID": operationID.uuidString.lowercased(),
         "CMUX_CLOUD_TRACE_ID": traceID, "CMUX_CLOUD_PARENT_SPAN_ID": spanID]
    }

    public func withPhase<T>(
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

    public static func phase<T>(
        _ phase: CloudOperationPhase, attempt: Int = 0, file: StaticString = #fileID, line: UInt = #line,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        if let current { return try await current.withPhase(phase, attempt: attempt, file: file, line: line, work) }
        return try await work()
    }
}
