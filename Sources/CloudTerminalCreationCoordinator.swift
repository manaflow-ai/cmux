import Foundation

/// Coordinates one asynchronous Cloud terminal creation behind a reserved pane.
///
/// The coordinator retains a creation result after the remote terminal is born. If the
/// first local projection fails while `cmux-tui` is restarting, Retry reuses that terminal
/// instead of creating a second one.
@MainActor
final class CloudTerminalCreationCoordinator {
    typealias Create = @MainActor () async throws -> SurfaceResource
    typealias Project = @MainActor (SurfaceResource) async throws -> (projection: SurfaceProjection, reused: Bool)
    typealias DiscardProjection = @MainActor (SurfaceProjection) -> Void

    private let create: Create
    private let project: Project
    private let discardProjection: DiscardProjection
    private let onStart: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void
    private let onCancel: @MainActor () -> Void
    private let onSuccess: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var creationTask: Task<SurfaceResource, Error>?
    private var cancelled = false
    private var createdResource: SurfaceResource?

    /// Runs the same create/project lifecycle for every optimistic pane.
    init(
        create: @escaping Create,
        project: @escaping Project,
        onStart: @escaping @MainActor () -> Void = {},
        onFailure: @escaping @MainActor (Error) -> Void,
        onCancel: @escaping @MainActor () -> Void = {},
        onSuccess: @escaping @MainActor () -> Void,
        discardProjection: @escaping DiscardProjection = { _ in }
    ) {
        self.create = create
        self.project = project
        self.onStart = onStart
        self.onFailure = onFailure
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.discardProjection = discardProjection
    }

    /// Shares the exact create receipt with shortcuts anchored to the pending pane.
    func resource() async throws -> SurfaceResource {
        guard !cancelled else { throw CancellationError() }
        if let createdResource { return createdResource }
        if creationTask == nil {
            let create = self.create
            creationTask = Task { @MainActor in try await create() }
        }
        let resource = try await creationTask!.value
        guard !cancelled else { throw CancellationError() }
        createdResource = resource
        return resource
    }

    /// Begins creation or retries the last remote resource's local projection.
    func start() {
        // A repeated retry is still the same intent. Cancelling a create can
        // discard its receipt after the remote mutation has already committed.
        guard task == nil, !cancelled else { return }
        generation &+= 1
        let operationGeneration = generation
        onStart()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == operationGeneration { self.task = nil }
            }
            do {
                let resource = try await self.resource()
                guard self.generation == operationGeneration else { return }
                try Task.checkCancellation()
                let projectionResult = try await self.project(resource)
                guard self.generation == operationGeneration,
                      !Task.isCancelled else {
                    if !projectionResult.reused {
                        self.discardProjection(projectionResult.projection)
                    }
                    return
                }
                self.onSuccess()
            } catch is CancellationError {
                if self.generation == operationGeneration { self.onCancel() }
                return
            } catch {
                guard self.generation == operationGeneration,
                      !Task.isCancelled else { return }
                self.onFailure(error)
            }
        }
    }

    /// Retries the current operation while preserving any successfully-created resource.
    func retry() {
        start()
    }

    /// Cancels work when the user closes the temporary pane.
    func cancel() {
        cancelled = true
        generation &+= 1
        creationTask?.cancel()
        task?.cancel()
        task = nil
        onCancel()
    }

    deinit {
        creationTask?.cancel()
        task?.cancel()
    }
}
