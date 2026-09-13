import CmuxAuthRuntime
import Foundation
import Observation

/// One state owner supplies the Machines UI, debug socket and diagnostic exporter.
@MainActor
@Observable
final class CloudOperationRecorder {
    private(set) var operations: [CloudOperationSnapshot] = []
    @ObservationIgnored private let uploader: (any CloudTelemetrySending)?
    @ObservationIgnored private let identity: @MainActor () -> AuthenticatedSessionIdentity?
    @ObservationIgnored private var active: [String: CloudOperationContext] = [:]
    @ObservationIgnored private var authObserver: NSObjectProtocol?

    init(uploader: (any CloudTelemetrySending)? = nil, identity: @escaping @MainActor () -> AuthenticatedSessionIdentity? = { nil }) {
        self.uploader = uploader
        self.identity = identity
        authObserver = NotificationCenter.default.addObserver(forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    deinit { if let authObserver { NotificationCenter.default.removeObserver(authObserver) } }

    func begin(_ operation: CloudOperationKind, foreground: Bool = true, file: StaticString = #fileID, line: UInt = #line) -> CloudOperationContext {
        let trace = VMRequestTraceContext.mint()
        let context = CloudOperationContext(
            recorder: self, identity: identity(), operationID: UUID(), traceID: trace.traceId,
            spanID: trace.spanId, parentSpanID: nil, operation: operation, phase: .operation,
            attempt: 0, startedAt: Date(), clock: .now,
            sourceFile: String(describing: file).split(separator: "/").last.map(String.init) ?? "unknown.swift", sourceLine: Int(line)
        )
        operations.append(CloudOperationSnapshot(
            id: context.operationID, traceID: context.traceID, operation: operation,
            startedAt: context.startedAt, foreground: foreground, steps: [], outcome: nil, failure: nil
        ))
        active[context.spanID] = context
        trim()
        return context
    }

    func beginChild(of parent: CloudOperationContext, phase: CloudOperationPhase, attempt: Int, file: StaticString = #fileID, line: UInt = #line) -> CloudOperationContext {
        let child = CloudOperationContext(
            recorder: self, identity: parent.identity, operationID: parent.operationID, traceID: parent.traceID,
            spanID: VMRequestTraceContext.mint().spanId, parentSpanID: parent.spanID,
            operation: parent.operation, phase: phase, attempt: attempt, startedAt: Date(), clock: .now,
            sourceFile: String(describing: file).split(separator: "/").last.map(String.init) ?? "unknown.swift", sourceLine: Int(line)
        )
        active[child.spanID] = child
        if let index = operations.firstIndex(where: { $0.id == parent.operationID }) {
            operations[index].steps.append(.init(id: child.spanID, phase: phase, startedAt: child.startedAt))
        }
        return child
    }

    func reference(operationID: String?, traceID: String?, spanID: String?) -> CloudOperationContext? {
        guard let spanID, let value = active[spanID], value.operationID.uuidString.lowercased() == operationID,
              value.traceID == traceID, value.identity == identity() else { return nil }
        return value
    }

    func applyRemoteSteps(_ steps: [CloudRemoteOperationStep], context: CloudOperationContext) {
        guard active[context.spanID] != nil,
              let index = operations.firstIndex(where: { $0.id == context.operationID }) else { return }
        for step in steps.prefix(64) {
            let value = CloudOperationSnapshot.Step(
                id: step.id, phase: step.phase, startedAt: Date(timeIntervalSince1970: Double(step.startedAtMs) / 1000),
                outcome: CloudTelemetrySpan.Outcome(rawValue: step.outcome),
                durationMs: step.endedAtMs.map { max(0, $0 - step.startedAtMs) }, isRemote: true
            )
            if let existing = operations[index].steps.firstIndex(where: { $0.id == step.id }) {
                operations[index].steps[existing] = value
            } else {
                operations[index].steps.append(value)
            }
        }
    }

    func finish(_ context: CloudOperationContext, error: Error? = nil, httpStatus: Int? = nil) async {
        guard active.removeValue(forKey: context.spanID) != nil else { return }
        let failure = error.map(CloudDiagnosticFailure.classify)
            ?? httpStatus.flatMap { $0 >= 400 ? CloudDiagnosticFailure.classify(status: $0) : nil }
        let outcome: CloudTelemetrySpan.Outcome = failure == .cancelled ? .cancelled
            : failure == .timeout ? .timeout : failure == nil ? .success : .failure
        let duration = context.clock.duration(to: .now)
        let milliseconds = max(0, duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        if let index = operations.firstIndex(where: { $0.id == context.operationID }) {
            if context.phase == .request {
                for step in operations[index].steps.indices where operations[index].steps[step].isRemote && operations[index].steps[step].outcome == nil {
                    operations[index].steps[step].outcome = outcome
                }
            }
            if context.parentSpanID == nil {
                operations[index].outcome = outcome
                operations[index].failure = failure
            } else if let step = operations[index].steps.firstIndex(where: { $0.id == context.spanID }) {
                operations[index].steps[step].outcome = outcome
                operations[index].steps[step].failure = failure
                operations[index].steps[step].durationMs = milliseconds
            }
            if failure != nil && failure != .cancelled { operations[index].foreground = true }
        }
        let start = Int64(context.startedAt.timeIntervalSince1970 * 1000)
        let span = CloudTelemetrySpan(
            eventId: UUID().uuidString.lowercased(), operationId: context.operationID.uuidString.lowercased(),
            traceId: context.traceID, spanId: context.spanID, parentSpanId: context.parentSpanID,
            operation: context.operation, phase: context.phase, outcome: outcome,
            startedAtMs: start, endedAtMs: start + milliseconds, attempt: context.attempt,
            failure: failure, httpStatus: httpStatus, errorNumber: (error as? URLError)?.code.rawValue,
            sourceFile: context.sourceFile, sourceLine: context.sourceLine
        )
        if let uploader, let identity = context.identity {
            await uploader.enqueue(span, identity: identity)
        }
        trim()
    }

    nonisolated func perform<T>(
        _ operation: CloudOperationKind, foreground: Bool = true, file: StaticString = #fileID, line: UInt = #line,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let root = await begin(operation, foreground: foreground, file: file, line: line)
        return try await CloudOperationContext.$current.withValue(root) {
            do {
                let value = try await work()
                await finish(root)
                return value
            } catch {
                await finish(root, error: error)
                throw error
            }
        }
    }

    func dismiss(_ id: UUID) { operations.removeAll { $0.id == id && !$0.isRunning } }
    func reset() {
        operations.removeAll()
        active.removeAll()
        if let uploader { Task { await uploader.clearForSignOut() } }
    }

    private func trim() {
        while operations.count > 100, let index = operations.firstIndex(where: { !$0.isRunning && !$0.needsAttention }) {
            operations.remove(at: index)
        }
        while operations.count > 200, let index = operations.firstIndex(where: { !$0.isRunning }) {
            operations.remove(at: index)
        }
    }
}
