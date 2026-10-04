public import CmuxHomeCore
public import Foundation
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
    /// the host can say why (iOS: an alert with `HomeText.explanation(for:)`).
    /// A refused send restores its draft instead.
    public var onRefusal: (HomeIntent, HomeRejection) -> Void = { _, _ in }
    /// Loads attachment bytes for rows of this conversation
    /// (`HomeStore.fetchAttachment(_:variant:in:)`): this client's own copy
    /// when it has one, else the source. The render core
    /// has no attachment hook yet; lane 16 passes this to the controller
    /// when it adds one.
    public var fetchAttachment: @Sendable (AttachmentRef, AttachmentVariant) async throws -> URL

    public init(store: HomeStore, controller: HomeController) {
        self.store = store
        self.controller = controller
        let id = controller.conversation
        self.fetchAttachment = { [weak store] ref, variant in
            guard let store else { throw CancellationError() }
            return try await store.fetchAttachment(ref, variant: variant, in: id)
        }
        controller.onIntent = { [weak self] intent in self?.perform(intent) }
        controller.onNeedsOlder = { [weak store] in
            guard let store else { return }
            Task { await store.loadOlder(id) }
        }
        refresh()
        observe()
    }

    /// Stops forwarding (the conversation closed) and closes the
    /// conversation on the store, pairing the host's `HomeStore.open`.
    public func stop() {
        guard !stopped else { return }
        store.close(controller.conversation)
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
        Task { [weak self] in
            do {
                _ = try await store.perform(intent.op, key: intent.key)
            } catch let rejection as HomeRejection {
                // Refused before it reached the log (offline, nothing queues):
                // give the text back. A logged refusal stays as "Not Delivered".
                guard case .sendMessage(let id, _) = intent.op else {
                    if let self, !self.stopped { self.onRefusal(intent, rejection) }
                    return
                }
                if !store.transcript(for: id).contains(where: { $0.key == intent.key }) {
                    controller.restoreDraft(for: intent.key)
                }
            } catch {
                // HomeSendState.pendingResend: the store resends with the same key.
            }
        }
    }
}
