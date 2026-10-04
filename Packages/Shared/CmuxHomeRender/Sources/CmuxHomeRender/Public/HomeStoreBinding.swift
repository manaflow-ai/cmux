public import CmuxHomeCore
import Observation

/// Connects one `HomeController` to a `HomeStore`: store changes reach
/// `update` (observed, no polling) and the controller's intents go to
/// `HomeStore.perform` with their idempotency keys. Hosts that own their own
/// plumbing can call `update` and handle `onIntent` themselves instead.
@MainActor
public final class HomeStoreBinding {
    public let store: HomeStore
    public let controller: HomeController
    private var stopped = false
    /// A refused op other than a send (a tapback now), on the main actor, so
    /// the host can say why. Not called yet (the red test of item 9).
    public var onRefusal: (HomeIntent, HomeRejection) -> Void = { _, _ in }

    public init(store: HomeStore, controller: HomeController) {
        self.store = store
        self.controller = controller
        let id = controller.conversation
        controller.onIntent = { [weak self] intent in self?.perform(intent) }
        controller.onNeedsOlder = { [weak store] in
            guard let store else { return }
            Task { await store.loadOlder(id) }
        }
        refresh()
        observe()
    }

    /// Stops forwarding (the conversation closed).
    public func stop() {
        stopped = true
        controller.onIntent = { _ in }
        controller.onNeedsOlder = {}
    }

    private func refresh() {
        let id = controller.conversation
        controller.update(items: store.transcript(for: id), summary: store.summary(id), typing: store.typing[id] ?? [],
                          hasOlder: store.hasOlderMessages(in: id))
    }

    /// Re-registers after every change. `rows` changes with every summary
    /// change (read cursors, participants); the controller ignores updates
    /// that change nothing it shows.
    private func observe() {
        guard !stopped else { return }
        let id = controller.conversation
        withObservationTracking {
            _ = store.transcriptVersion[id]
            _ = store.typing[id]
            _ = store.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func perform(_ intent: HomeIntent) {
        let store = self.store
        let controller = self.controller
        Task {
            do {
                _ = try await store.perform(intent.op, key: intent.key)
            } catch is HomeRejection {
                // Refused before it reached the log (offline, nothing queues):
                // give the text back. A logged refusal stays as "Not Delivered".
                if case .sendMessage(let id, _) = intent.op, !store.transcript(for: id).contains(where: { $0.key == intent.key }) {
                    controller.restoreDraft(for: intent.key)
                }
            } catch {
                // HomeSendState.pendingResend: the store resends with the same key.
            }
        }
    }
}
