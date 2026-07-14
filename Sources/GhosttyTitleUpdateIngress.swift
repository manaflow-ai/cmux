import Foundation
import os

/// Synchronous callback ingress: duplicate titles are rejected before an
/// asynchronous message is allocated, and the lock preserves callback order
/// through the single long-lived stream consumer.
final class GhosttyTitleUpdateIngress: Sendable {
    private enum Message: Sendable {
        case update(GhosttyTitleUpdate)
        case retire(tabId: UUID, surfaceId: UUID, sourceSurfaceIdentifier: ObjectIdentifier)
    }

    private struct SurfaceKey: Hashable, Sendable {
        let tabId: UUID
        let surfaceId: UUID
        let sourceSurfaceIdentifier: ObjectIdentifier
    }

    private struct State: Sendable {
        var sequence: UInt64 = 0
        var lastTitleBySurface: [SurfaceKey: String] = [:]
    }

    // Ghostty's synchronous C callback cannot await; this O(1) lock only gates dedupe and message ordering.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: AsyncStream<Message>.Continuation
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
        let (stream, continuation) = AsyncStream.makeStream(of: Message.self)
        self.continuation = continuation
        consumerTask = Task {
            for await message in stream {
                switch message {
                case .update(let update):
                    await dispatcher.receive(update)
                case .retire(let tabId, let surfaceId, let sourceSurfaceIdentifier):
                    await dispatcher.retire(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        sourceSurfaceIdentifier: sourceSurfaceIdentifier
                    )
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    func submit(tabId: UUID, surfaceId: UUID, sourceSurface: AnyObject, title: String) {
        let sourceSurfaceIdentifier = ObjectIdentifier(sourceSurface)
        let key = SurfaceKey(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        )
        state.withLock { state in
            guard state.lastTitleBySurface[key] != title else { return }
            state.lastTitleBySurface[key] = title
            state.sequence &+= 1
            _ = continuation.yield(.update(GhosttyTitleUpdate(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                sourceSurfaceIdentifier: sourceSurfaceIdentifier,
                sequence: state.sequence
            )))
        }
    }

    func retire(tabId: UUID, surfaceId: UUID, sourceSurface: AnyObject) {
        let sourceSurfaceIdentifier = ObjectIdentifier(sourceSurface)
        let key = SurfaceKey(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier
        )
        state.withLock { state in
            guard state.lastTitleBySurface.removeValue(forKey: key) != nil else { return }
            _ = continuation.yield(.retire(
                tabId: tabId,
                surfaceId: surfaceId,
                sourceSurfaceIdentifier: sourceSurfaceIdentifier
            ))
        }
    }
}
