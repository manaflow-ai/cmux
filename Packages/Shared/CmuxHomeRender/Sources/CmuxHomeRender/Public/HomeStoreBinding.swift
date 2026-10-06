public import CmuxHomeCore
public import Foundation
import Observation

/// Connects one `HomeController` to a `HomeStore`: store changes reach
/// `update` (observed, no polling) and the controller's intents go to
/// `HomeStore.perform` with their idempotency keys. Hosts that own their own
/// transcript plumbing (the Mac MessagesLab host) use
/// `init(store:conversation:)`: the binding then carries only the
/// conversation's part of the store, its refusals, unanswered ops,
/// attachment fetches and Cancel Upload.
///
/// The binding owns its conversation's open/close pair: it opens the
/// conversation on the store when it starts and `stop()` closes exactly
/// that open, also when it stops while the first page loads (the store
/// drops that page). Hosts do not call `HomeStore.open` themselves. A
/// binding freed without `stop()` closes that open from its deinit.
@MainActor
public final class HomeStoreBinding {
    public let store: HomeStore
    /// Nil for a host with its own transcript (`init(store:conversation:)`).
    public let controller: HomeController?
    public let conversation: ConversationID
    private var stopped = false
    /// This binding's entry in the store's hooks for its conversation:
    /// registered at init, unregistered by `stop()` (the store holds it
    /// weakly, so a binding freed without stopping leaves nothing behind).
    private let hooks: HomeConversationHooks
    /// The first page load this binding's open started.
    private var opening: Task<Void, Never>?
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
        didSet { controller?.attachmentLoader = HomeFetchLoader(fetch: fetchAttachment) }
    }
    /// A send the client refused before logging it because of an
    /// attachment (type, size, empty file, too many parts); its draft and
    /// attachments went back to the host's field.
    public var onAttachmentRefusal: (HomeIntent, HomeAttachmentError) -> Void = { _, _ in }
    /// One of my sends was logged and then refused (its row shows "Not
    /// Delivered"): the host can say why (for example a conversation whose
    /// owner stores no attachments). `retry` or Cancel stay on the row.
    public var onSendNotDelivered: (HomeIntent, HomeRejection) -> Void = { _, _ in }
    /// An op of this conversation other than a send (a tapback, a read
    /// cursor) ran out of resends unanswered: it may not have gone through.
    public var onUnanswered: (HomeIntent) -> Void = { _ in }

    public convenience init(store: HomeStore, controller: HomeController) {
        self.init(store: store, conversation: controller.conversation, controller: controller)
        controller.attachmentLoader = HomeFetchLoader(fetch: fetchAttachment)
        controller.onIntent = { [weak self] intent in self?.perform(intent) }
        let id = conversation
        controller.onNeedsOlder = { [weak store] in
            guard let store else { return }
            Task { await store.loadOlder(id) }
        }
        refresh()
        observe()
    }

    /// A binding for a host that shows and updates the transcript itself:
    /// `onRefusal`, `onUnanswered`, `fetchAttachment` and `cancelSend` for
    /// `conversation`, chained with every other binding of the store.
    public convenience init(store: HomeStore, conversation: ConversationID) {
        self.init(store: store, conversation: conversation, controller: nil)
    }

    private init(store: HomeStore, conversation id: ConversationID, controller: HomeController?) {
        self.store = store
        self.controller = controller
        conversation = id
        hooks = HomeConversationHooks(conversation: id)
        self.fetchAttachment = { [weak store] ref, variant in
            guard let store else { throw CancellationError() }
            return try await store.fetchAttachment(ref, variant: variant, in: id)
        }
        // Refusals and unanswered ops nobody awaits (a resumed upload, a
        // resend after backoff) reach the host like any other: the store
        // tells every live binding of this conversation, once each. The
        // store snapshots the hooks before a delivery, so a binding stopped
        // by an earlier handler of the same intent checks `stopped` itself.
        hooks.onRefusal = { [weak self] intent, rejection in
            guard let self, !self.stopped else { return }
            self.onRefusal(intent, rejection)
        }
        hooks.onUnanswered = { [weak self] intent in
            guard let self, !self.stopped else { return }
            self.onUnanswered(intent)
        }
        store.register(hooks)
        // Counted as shown at once, so the `close` in `stop()` always pairs with it.
        opening = store.beginOpen(id)
    }

    /// Returns once the conversation's first page is in (at once when it
    /// already was), for hosts that draw only after it.
    public func opened() async {
        await opening?.value
    }

    /// Cancels my pending send `key` (an upload, a queued send or a failed
    /// one; `HomeController.cancellableSend` says when it can). The row leaves
    /// the transcript. Returns false when the store could not cancel it.
    @discardableResult
    public func cancelSend(_ key: IdempotencyKey) -> Bool {
        store.cancelSend(key)
    }

    /// Stops forwarding (the conversation closed) and closes the
    /// conversation on the store, pairing the binding's own open. A second
    /// call does nothing.
    public func stop() {
        guard !stopped else { return }
        store.close(conversation)
        store.unregister(hooks)
        stopped = true
        controller?.onIntent = { _ in }
        controller?.onNeedsOlder = {}
    }

    /// Freed without `stop()` (a host that went away without a last
    /// callback): closes the binding's open and drops its hooks on the
    /// main actor, at once when the last reference went on it. On the main
    /// thread `hooks` is still alive here (stored properties go after the
    /// deinit body), so pruning freed entries would keep it: it is
    /// unregistered by identity instead. Off the main thread the hop runs
    /// after `hooks` is freed, so pruning drops it without keeping it alive.
    /// An `isolated deinit` would need iOS 18.4 and macOS 15.4.
    deinit {
        guard !stopped else { return }
        let store = store
        let id = conversation
        if Thread.isMainThread {
            let hooks = hooks
            MainActor.assumeIsolated {
                store.close(id)
                store.unregister(hooks)
            }
        } else {
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in
                store.close(id)
                store.pruneHooks(for: id)
            }
        }
    }

    private func refresh() {
        guard let controller else { return }
        let id = conversation
        controller.update(items: store.transcript(for: id), summary: store.summary(id), typing: store.typing[id] ?? [],
                          hasOlder: store.hasOlderMessages(in: id))
    }

    /// Re-registers after every change. `rows` changes with every summary
    /// change (read cursors, participants); the controller ignores updates
    /// that change nothing it shows.
    private func observe() {
        guard !stopped, controller != nil else { return }
        let id = conversation
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
        guard let controller else { return }
        let store = self.store
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
                } else if let self, !self.stopped {
                    self.onSendNotDelivered(intent, rejection)
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
