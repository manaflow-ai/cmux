import Foundation

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

    private weak var panel: CloudTerminalPendingPanel?
    private let create: Create
    private let project: Project
    private let discardProjection: DiscardProjection
    private let onSuccess: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var createdResource: SurfaceResource?

    init(
        panel: CloudTerminalPendingPanel,
        create: @escaping Create,
        project: @escaping Project,
        onSuccess: @escaping @MainActor () -> Void,
        discardProjection: @escaping DiscardProjection = { _ in }
    ) {
        self.panel = panel
        self.create = create
        self.project = project
        self.onSuccess = onSuccess
        self.discardProjection = discardProjection
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
                let resource: SurfaceResource
                if let createdResource = self.createdResource {
                    resource = createdResource
                } else {
                    resource = try await self.create()
                    guard self.generation == operationGeneration else { return }
                    self.createdResource = resource
                }
                try Task.checkCancellation()
                let projectionResult = try await self.project(resource)
                guard self.generation == operationGeneration,
                      !Task.isCancelled,
                      self.panel === panel else {
                    if !projectionResult.reused {
                        self.discardProjection(projectionResult.projection)
                    }
                    return
                }
                self.onSuccess()
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
