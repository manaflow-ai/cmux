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

    /// Starts event consumption, reconciles the durable spool, and presents requests.
    ///
    /// - Throws: A broker startup error when the durable spool cannot be observed safely.
    public func start() async throws {
        guard eventTask == nil else { return }
        let events = await broker.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }

        do {
            let snapshots = try await broker.start()
            for snapshot in snapshots {
                present(snapshot)
            }
        } catch {
            eventTask?.cancel()
            eventTask = nil
            throw error
        }
    }

    /// Stops observation and dismisses UI without abandoning bounded runners.
    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        presenter.dismissAll()
        presentations.removeAll()
        await broker.stop()
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
        switch event {
        case .discovered(let snapshot):
            present(snapshot)
        case .phaseChanged(let id, let phase):
            presentations[id]?.update(phase: phase)
        case .settled(let result):
            presenter.dismiss(id: result.id)
            presentations.removeValue(forKey: result.id)
        }
    }

    private func present(_ snapshot: SudoPendingRequest) {
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
}
