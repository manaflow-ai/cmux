import Foundation
import os

/// Synchronous callback ingress: duplicate titles are rejected before an
/// asynchronous message is allocated, and the mailbox preserves per-surface
/// callback order through the single long-lived stream consumer.
final class GhosttyTitleUpdateIngress: Sendable {
    // Ghostty's synchronous C callback cannot await; this O(1) lock owns a
    // latest-value mailbox per surface. The stream carries only a bounded
    // wake-up token, never one retained String per title callback.
    private let mailbox: OSAllocatedUnfairLock<GhosttyTitleUpdateMailbox>
    private let wakeupContinuation: AsyncStream<Void>.Continuation
    private let consumerTask: Task<Void, Never>

    init(center: NotificationCenter = .default) {
        let dispatcher = GhosttyTitleUpdateDispatcher { updates in
#if DEBUG
            let timingStart = CmuxTypingTiming.start()
#endif
            for update in updates {
                let change = GhosttyTitleChange(
                    tabId: update.tabId,
                    surfaceId: update.surfaceId,
                    title: update.title,
                    sourceSurfaceIdentifier: update.sourceSurfaceIdentifier
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
        let mailbox = OSAllocatedUnfairLock(initialState: GhosttyTitleUpdateMailbox())
        let (wakeups, wakeupContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.mailbox = mailbox
        self.wakeupContinuation = wakeupContinuation
        consumerTask = Task {
            for await _ in wakeups {
                let operations = mailbox.withLock { $0.takePendingOperations() }
                for operation in operations {
                    if let retirement = operation.retirement {
                        await dispatcher.retire(
                            tabId: retirement.tabId,
                            surfaceId: retirement.surfaceId,
                            sourceSurfaceIdentifier: retirement.sourceSurfaceIdentifier
                        )
                    }
                    if let update = operation.update {
                        await dispatcher.receive(update)
                    }
                }
            }
        }
    }

    deinit {
        wakeupContinuation.finish()
        consumerTask.cancel()
    }

    func submit(tabId: UUID, surfaceId: UUID, sourceSurface: AnyObject, title: String) {
        let sourceSurfaceIdentifier = ObjectIdentifier(sourceSurface)
        let shouldWake = mailbox.withLock {
            $0.submit(
                tabId: tabId,
                surfaceId: surfaceId,
                sourceSurfaceIdentifier: sourceSurfaceIdentifier,
                title: title,
            )
        }
        if shouldWake {
            _ = wakeupContinuation.yield(())
        }
    }

    func retire(tabId: UUID, surfaceId: UUID, sourceSurface: AnyObject) {
        let sourceSurfaceIdentifier = ObjectIdentifier(sourceSurface)
        let shouldWake = mailbox.withLock {
            $0.retire(
                tabId: tabId,
                surfaceId: surfaceId,
                sourceSurfaceIdentifier: sourceSurfaceIdentifier
            )
        }
        if shouldWake {
            _ = wakeupContinuation.yield(())
        }
    }
}
