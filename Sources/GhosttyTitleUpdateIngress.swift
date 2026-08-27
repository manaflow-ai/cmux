import CmuxFoundation
import CmuxTerminalCore
import Foundation

/// Synchronous callback ingress: duplicate titles are rejected before an
/// asynchronous message is enqueued. Each ingress belongs to one Ghostty view,
/// so its newest-value stream preserves that view's final title without a
/// process-global mailbox or cross-surface contention.
final class GhosttyTitleUpdateIngress {
    private let attachmentGeneration: AtomicUInt64Generation
    private let dispatcher: GhosttyTitleUpdateDispatcher
    private let titleChurnFilter: TerminalTitleChurnFilter
    private let continuation: AsyncStream<GhosttyTitleUpdate>.Continuation
    private let consumerTask: Task<Void, Never>
    /// Ghostty serializes action callbacks for a view; no other context reads
    /// or writes this duplicate-rejection snapshot.
    private var lastSubmittedUpdate: GhosttyTitleUpdate?
    init(
        center: NotificationCenter = .default,
        titleChurnFilter: TerminalTitleChurnFilter = TerminalTitleChurnFilter(),
        schedule: GhosttyTitleUpdateDispatcher.Scheduler? = nil
    ) {
        let attachmentGeneration = AtomicUInt64Generation()
        let dispatcher = GhosttyTitleUpdateDispatcher(
            attachmentGeneration: attachmentGeneration,
            schedule: schedule
        ) { updates in
#if DEBUG
            let timingStart = CmuxTypingTiming.start()
#endif
            for update in updates {
                let change = GhosttyTitleChange(
                    tabId: update.tabId,
                    surfaceId: update.surfaceId,
                    title: update.title,
                    sourceSurfaceIdentifier: update.sourceSurfaceIdentifier,
                    terminalLifecycleID: update.terminalLifecycleID
                )
                center.post(name: .ghosttyDidSetTitle, object: nil, userInfo: change.userInfo)
            }
#if DEBUG
            CmuxTypingTiming.logDuration(
                path: "title.publish",
                startedAt: timingStart,
                extra: "published=\(updates.count)"
            )
#endif
        }
        let (updates, continuation) = AsyncStream<GhosttyTitleUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.attachmentGeneration = attachmentGeneration
        self.dispatcher = dispatcher
        self.titleChurnFilter = titleChurnFilter
        self.continuation = continuation
        consumerTask = Task {
            for await update in updates {
                await dispatcher.receive(update)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Returns false when normalization removes a label-less spinner frame,
    /// when the update duplicates the callback-local snapshot, or when the
    /// ingress has already terminated.
    @discardableResult
    func submit(
        tabId: UUID,
        surfaceId: UUID,
        sourceSurfaceIdentifier: ObjectIdentifier,
        terminalLifecycleID: UUID,
        title: String,
        titleOverride: String? = nil
    ) -> Bool {
        let stableTitle: String
        if let titleOverride {
            stableTitle = titleOverride
        } else if let churnStableTitle = titleChurnFilter.stableTitle(for: title) {
            stableTitle = churnStableTitle
        } else {
            return false
        }
        let update = GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: stableTitle,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            attachmentGeneration: attachmentGeneration.loadRelaxed()
        )
        guard update != lastSubmittedUpdate else { return false }
        lastSubmittedUpdate = update
        switch continuation.yield(update) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func retireCurrentAttachment() {
        let nextGeneration = attachmentGeneration.advanceRelaxed()
        Task { [dispatcher] in
            await dispatcher.retireUpdates(before: nextGeneration)
        }
    }
}
