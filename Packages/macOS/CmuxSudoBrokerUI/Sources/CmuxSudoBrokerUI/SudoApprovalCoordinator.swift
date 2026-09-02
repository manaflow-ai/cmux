public import CmuxSudoBroker
public import Observation

/// Projects the authoritative sudo lifecycle into review-window state.
@MainActor @Observable
public final class SudoApprovalCoordinator {
    /// The request models currently owned by the approval flow.
    public private(set) var presentations: [String: SudoApprovalPresentation] = [:]

    @ObservationIgnored private let broker: any SudoBrokerServing
    @ObservationIgnored private let presenter: any SudoApprovalPresenting
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStartFailureHandler:
        (@MainActor @Sendable (any Error) -> Void)?
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var lifecycle = Lifecycle.idle

    /// Creates an approval coordinator with injected lifecycle and presentation seams.
    ///
    /// - Parameters:
    ///   - broker: The single authoritative sudo lifecycle owner.
    ///   - presenter: The review-window presentation owner.
    public init(
        broker: any SudoBrokerServing,
        presenter: any SudoApprovalPresenting
    ) {
        self.broker = broker
        self.presenter = presenter
    }

    /// Whether the app must join approval shutdown before terminating.
    public var requiresShutdown: Bool {
        lifecycle != .idle || startupTask != nil || shutdownTask != nil
    }

    /// Starts the approval lifecycle from a synchronous AppKit callback.
    ///
    /// - Parameter onFailure: A callback for a safe broker-startup failure.
    public func start(
        onFailure: @MainActor @Sendable @escaping (any Error) -> Void
    ) {
        if isStopping || shutdownTask != nil {
            pendingStartFailureHandler = onFailure
            return
        }
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { startupTask = nil }
            do {
                try await start()
            } catch {
                guard !Task.isCancelled, !isStopping else { return }
                onFailure(error)
            }
        }
    }

    /// Starts event consumption, reconciles the durable spool, and presents requests.
    ///
    /// - Throws: A broker startup error when the durable spool cannot be observed safely.
    public func start() async throws {
        guard lifecycle == .idle else { return }
        lifecycle = .starting
        let events = await broker.events()
        guard lifecycle == .starting, !Task.isCancelled else {
            if lifecycle == .starting {
                lifecycle = .idle
            }
            return
        }
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }

        do {
            let snapshots = try await broker.start()
            guard lifecycle == .starting, !Task.isCancelled else {
                eventTask?.cancel()
                eventTask = nil
                if lifecycle == .starting {
                    await broker.stop()
                    lifecycle = .idle
                }
                return
            }
            lifecycle = .running
            reconcile(snapshots)
        } catch {
            eventTask?.cancel()
            eventTask = nil
            await broker.stop()
            guard lifecycle == .starting else { return }
            presenter.dismissAll()
            presentations.removeAll()
            lifecycle = .idle
            guard !Task.isCancelled else { return }
            throw error
        }
    }

    /// Stops observation and dismisses UI without abandoning bounded runners.
    public func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isStopping = true
        let activeStartupTask = startupTask
        activeStartupTask?.cancel()
        lifecycle = .stopping
        eventTask?.cancel()
        eventTask = nil
        presenter.dismissAll()
        presentations.removeAll()
        let broker = self.broker
        let task = Task { await broker.stop() }
        shutdownTask = task
        await task.value
        await activeStartupTask?.value
        startupTask = nil
        shutdownTask = nil
        lifecycle = .idle
        isStopping = false
        let pendingStartFailureHandler = self.pendingStartFailureHandler
        self.pendingStartFailureHandler = nil
        if let pendingStartFailureHandler {
            start(onFailure: pendingStartFailureHandler)
        }
    }

    /// Applies the user's approval through the shared broker mutation path.
    ///
    /// - Parameter id: The reviewed request identifier.
    public func approve(id: String) async {
        guard let presentation = presentations[id], presentation.canDecide else { return }
        presentation.beginDecision()
        await broker.approve(id: id)
    }

    /// Applies the user's denial through the shared broker mutation path.
    ///
    /// - Parameter id: The reviewed request identifier.
    public func deny(id: String) async {
        guard let presentation = presentations[id], presentation.canDecide else { return }
        presentation.beginDecision()
        await broker.deny(id: id)
    }

    private func receive(_ event: SudoBrokerEvent) {
        guard lifecycle == .starting || lifecycle == .running else { return }
        switch event {
        case .snapshot(let snapshots):
            reconcile(snapshots)
        }
    }

    private func reconcile(_ snapshots: [SudoPendingRequest]) {
        guard lifecycle == .starting || lifecycle == .running else { return }
        let activeIDs = Set(snapshots.map(\.request.id))
        for id in Array(presentations.keys) where !activeIDs.contains(id) {
            presenter.dismiss(id: id)
            presentations.removeValue(forKey: id)
        }
        for snapshot in snapshots.sorted(by: {
            $0.request.id < $1.request.id
        }) {
            present(snapshot)
        }
    }

    private func present(_ snapshot: SudoPendingRequest) {
        guard lifecycle == .starting || lifecycle == .running else { return }
        if let existing = presentations[snapshot.request.id] {
            existing.update(phase: snapshot.phase)
            return
        }

        let presentation = SudoApprovalPresentation(snapshot: snapshot)
        presentations[snapshot.request.id] = presentation
        let id = snapshot.request.id
        presenter.present(
            presentation,
            approve: { [weak self] in await self?.approve(id: id) },
            deny: { [weak self] in await self?.deny(id: id) }
        )
    }

    /// Cancels local UI work after AppKit has entered synchronous teardown.
    public func cancelForImmediateTermination() {
        isStopping = true
        pendingStartFailureHandler = nil
        startupTask?.cancel()
        startupTask = nil
        lifecycle = .stopping
        eventTask?.cancel()
        eventTask = nil
        presenter.dismissAll()
        presentations.removeAll()
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
    }
}
