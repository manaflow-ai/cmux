import Foundation

/// Owns one optimistic Cloud pane and retains its acknowledged terminal across projection retries.
@MainActor
final class CloudTerminalCreationCoordinator {
    typealias Create = @MainActor () async throws -> SurfaceResource
    typealias Project = @MainActor (SurfaceResource) async throws -> (projection: SurfaceProjection, reused: Bool)
    typealias DiscardProjection = @MainActor (SurfaceProjection) -> Void

    private weak var panel: CloudTerminalPendingPanel?
    private let create: Create
    private let project: Project
    private let discardProjection: DiscardProjection
    private let onSuccess: @MainActor (SurfaceProjection) -> Void
    private let onStart: @MainActor () -> Void
    private let onFinish: @MainActor () -> Void
    private var task: Task<Void, Never>?
    private var creationTask: Task<SurfaceResource, Error>?
    private var createdResource: SurfaceResource?
    private var cancelled = false

    init(
        panel: CloudTerminalPendingPanel,
        create: @escaping Create,
        project: @escaping Project,
        onSuccess: @escaping @MainActor (SurfaceProjection) -> Void,
        discardProjection: @escaping DiscardProjection = { _ in },
        onStart: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor () -> Void = {}
    ) {
        self.panel = panel
        self.create = create
        self.project = project
        self.onSuccess = onSuccess
        self.discardProjection = discardProjection
        self.onStart = onStart
        self.onFinish = onFinish
    }

    /// Resolves a pending pane used as the anchor of another shortcut.
    /// The dependent request shares this create instead of issuing a second one.
    func resource() async throws -> SurfaceResource {
        guard !cancelled else { throw CancellationError() }
        if let createdResource { return createdResource }
        guard let creationTask else { throw CancellationError() }
        let resource = try await creationTask.value
        guard !cancelled else { throw CancellationError() }
        createdResource = resource
        return resource
    }

    func start() {
        guard task == nil, !cancelled else { return }
        panel?.resetForRetry()
        onStart()
        if creationTask == nil {
            let create = self.create
            creationTask = Task { @MainActor in try await create() }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.onFinish()
            }
            guard let panel = self.panel else { return }
            do {
                let resource = try await self.resource()
                try Task.checkCancellation()
                let result = try await self.project(resource)
                guard !self.cancelled, !Task.isCancelled, self.panel === panel else {
                    if !result.reused { self.discardProjection(result.projection) }
                    return
                }
                self.onSuccess(result.projection)
            } catch is CancellationError {
                if !self.cancelled { panel.showFailure(canRetry: self.createdResource != nil) }
            } catch {
                guard !self.cancelled, !Task.isCancelled, self.panel === panel else { return }
                #if DEBUG
                cmuxDebugLog("cloud.pane.createFailed machine=\(panel.machine.rawValue) error=\(String(reflecting: error))")
                #endif
                panel.showFailure(canRetry: self.createdResource != nil)
            }
        }
    }

    /// Only retries local projection of a terminal whose creation was acknowledged.
    /// An unknown remote create outcome is never replayed with a new identity.
    func retry() {
        guard createdResource != nil else { return }
        start()
    }

    func cancel() {
        cancelled = true
        creationTask?.cancel()
        task?.cancel()
        onFinish()
    }

    deinit {
        task?.cancel()
        creationTask?.cancel()
    }
}
