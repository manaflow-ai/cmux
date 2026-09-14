import Foundation
import os

nonisolated private let cloudTerminalCreationLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudTerminalCreation")

/// Coordinates one asynchronous Cloud terminal creation without leaving an empty pane.
///
/// The coordinator retains a creation result after the remote terminal is born. If the
/// first local projection fails while `cmux-tui` is restarting, Retry reuses that terminal
/// instead of creating a second one.
@MainActor
final class CloudTerminalCreationCoordinator {
    typealias Create = @MainActor () async throws -> SurfaceResource
    typealias Project = @MainActor (SurfaceResource) async throws -> (projection: SurfaceProjection, reused: Bool)
    typealias DiscardProjection = @MainActor (SurfaceProjection) -> Void
    typealias Failure = @MainActor (Error, CloudOperationContext?) -> Void

    private weak var panel: CloudTerminalPendingPanel?
    private let create: Create
    private let project: Project
    private let discardProjection: DiscardProjection
    private let onSuccess: @MainActor () -> Void
    private let onFailure: Failure
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var createdResource: SurfaceResource?

    init(
        panel: CloudTerminalPendingPanel,
        create: @escaping Create,
        project: @escaping Project,
        onSuccess: @escaping @MainActor () -> Void,
        discardProjection: @escaping DiscardProjection = { _ in },
        onFailure: @escaping Failure = { _, _ in }
    ) {
        self.panel = panel
        self.create = create
        self.project = project
        self.onSuccess = onSuccess
        self.discardProjection = discardProjection
        self.onFailure = onFailure
    }

    /// All Cloud terminal gestures establish a root before reaching the link.
    /// Its process/snapshot spans and the copied failure share one Axiom trace.
    static func perform<T>(
        recorder: CloudOperationRecorder?,
        file: StaticString = #fileID,
        line: UInt = #line,
        onFailure: Failure,
        _ work: @MainActor () async throws -> T
    ) async rethrows -> T {
        let context = recorder?.begin(.terminal, foreground: false, file: file, line: line)
        return try await CloudOperationContext.$current.withValue(context) {
            do {
                let value = try await work()
                if let context { await context.recorder.finish(context) }
                return value
            } catch {
                if CloudDiagnosticFailure.classify(error) != .cancelled {
                    cloudTerminalCreationLogger.error("Terminal creation failed: failure=\(CloudDiagnosticFailure.classify(error).rawValue, privacy: .public) trace=\(context?.traceID ?? "unavailable", privacy: .public) error=\(String(reflecting: error), privacy: .private)")
                    onFailure(error, context)
                }
                if let context { await context.recorder.finish(context, error: error) }
                throw error
            }
        }
    }

    /// Begins creation or retries the last remote resource's local projection.
    func start() {
        generation &+= 1
        let operationGeneration = generation
        task?.cancel()
        panel?.resetForRetry()
        task = Task { @MainActor [weak self] in
            guard let self, let panel = self.panel else { return }
            do {
                try await Self.perform(recorder: AppDelegate.shared?.cloudOperations, onFailure: { error, context in
                    guard self.generation == operationGeneration, !Task.isCancelled, self.panel === panel else { return }
                    self.onFailure(error, context)
                }) {
                    let resource: SurfaceResource
                    if let createdResource = self.createdResource {
                        resource = createdResource
                    } else {
                        resource = try await CloudOperationContext.phase(.provider, self.create)
                        guard self.generation == operationGeneration else { throw CancellationError() }
                        self.createdResource = resource
                    }
                    try Task.checkCancellation()
                    let projectionResult = try await CloudOperationContext.phase(.materialize) {
                        try await self.project(resource)
                    }
                    guard self.generation == operationGeneration,
                          !Task.isCancelled,
                          self.panel === panel else {
                        if !projectionResult.reused {
                            self.discardProjection(projectionResult.projection)
                        }
                        throw CancellationError()
                    }
                    self.onSuccess()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == operationGeneration,
                      !Task.isCancelled,
                      self.panel === panel else { return }
                panel.showFailure()
            }
        }
    }

    /// Retries the current operation while preserving any successfully-created resource.
    func retry() {
        start()
    }

    /// Cancels work when the user closes the temporary pane.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
