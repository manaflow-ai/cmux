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
    /// (`HomeStore.fetchAttachment(_:variant:in:)`): this
    /// client's own copy when it has one, else the source. It is the
    /// controller's `attachmentLoader` (thumbnails for bubbles, the
    /// original for video playback).
    public var fetchAttachment: @Sendable (AttachmentRef, AttachmentVariant) async throws -> URL {
        didSet { controller.attachmentLoader = HomeFetchLoader(fetch: fetchAttachment) }
    }
    /// A send the client refused before logging it because of an
    /// attachment (type, size, empty file, too many parts); its draft and
    /// attachments went back to the host's field.
    public var onAttachmentRefusal: (HomeIntent, HomeAttachmentError) -> Void = { _, _ in }

    public init(store: HomeStore, controller: HomeController) {
        self.store = store
        self.controller = controller
        let id = controller.conversation
        self.fetchAttachment = { [weak store] ref, variant in
            guard let store else { throw CancellationError() }
            return try await store.fetchAttachment(ref, variant: variant, in: id)
        }
        controller.attachmentLoader = HomeFetchLoader(fetch: fetchAttachment)
        // Refusals nobody awaits (a resumed upload, a resend after backoff)
        // reach the host like any other refusal. One store serves several
        // bindings: each takes its own conversation and passes the rest on.
        let previous = store.onRefusal
        store.onRefusal = { [weak self] intent, rejection in
            guard intent.op.conversation == id else { previous?(intent, rejection); return }
            guard let self, !self.stopped else { return }
            self.onRefusal(intent, rejection)
        }
        controller.onIntent = { [weak self] intent in self?.perform(intent) }
        controller.onNeedsOlder = { [weak store] in
            guard let store else { return }
            Task { await store.loadOlder(id) }
        }
        refresh()
        observe()
    }

    /// Stops forwarding (the conversation closed).
    /// Cancels my pending send `key` (an upload, a queued send or a failed
    /// one; `HomeController.cancellableSend` says when it can). The row leaves
    /// the transcript. Returns false when the store could not cancel it.
    @discardableResult
    public func cancelSend(_ key: IdempotencyKey) -> Bool {
        store.cancelSend(key)
    }

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
        Task { [weak self] in
            do {
                if let send = controller.attachmentSend(intent) {
                    try await store.send(conversation: send.conversation, text: send.text, attachments: send.attachments,
                                         key: intent.key)
                } else {
                    _ = try await store.perform(intent.op, key: intent.key)
                }
            } catch let refusal as HomeAttachmentError {
                // Refused before it was logged: the draft and its attachments go back.
                controller.restoreDraft(for: intent.key)
                if let self, !self.stopped { self.onAttachmentRefusal(intent, refusal) }
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
                // HomeSendState.pendingResend: the store resends with the same
                // key. HomeSendState.unanswered: a send keeps its "Not
                // Delivered" row; any other op reaches the host through
                // HomeStore.onUnanswered (it usually runs out on a resend
                // nobody awaits, so this call never sees it).
            }
        }
    }
}

/// The binding's fetch as the render core's loader.
struct HomeFetchLoader: HomeAttachmentLoader {
    var fetch: @Sendable (AttachmentRef, AttachmentVariant) async throws -> URL

    func thumbnail(for ref: AttachmentRef, maxPixel: Int) async throws -> URL {
        try await fetch(ref, .thumbnail(maxPixel: maxPixel))
    }

    /// `.poster` reads the video part's poster blob; a part without one
    /// throws (no_poster) and the bubble keeps its placeholder.
    func poster(for ref: AttachmentRef, maxPixel: Int) async throws -> URL {
        try await fetch(ref, .poster)
    }

    func original(for ref: AttachmentRef) async throws -> URL {
        try await fetch(ref, .original)
    }
}
