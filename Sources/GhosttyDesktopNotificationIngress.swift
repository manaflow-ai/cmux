import Foundation

/// Bounded handoff for OSC desktop notifications emitted by Ghostty.
///
/// The C callback cannot await main-actor routing or project-config I/O. A
/// single consumer preserves callback order, while `.bufferingNewest` caps
/// retained payloads and explicitly drops the oldest notification under a
/// sustained flood instead of growing an unbounded Task queue.
final class GhosttyDesktopNotificationIngress: Sendable {
    typealias Delivery = @MainActor @Sendable (GhosttyDesktopNotificationRequest) async -> Void

    private let continuation: AsyncStream<GhosttyDesktopNotificationRequest>.Continuation
    private let consumerTask: Task<Void, Never>

    init(maxBufferedRequests: Int = 256, delivery: Delivery? = nil) {
        let (stream, continuation) = AsyncStream<GhosttyDesktopNotificationRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, maxBufferedRequests))
        )
        self.continuation = continuation
        let resolvedDelivery = delivery ?? Self.deliver
        consumerTask = Task { @MainActor in
            for await request in stream {
                guard !Task.isCancelled else { return }
                await resolvedDelivery(request)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Returns false when the stream is terminated or this enqueue evicts the
    /// oldest buffered request under the documented overflow policy.
    @discardableResult
    func submit(_ request: GhosttyDesktopNotificationRequest) -> Bool {
        switch continuation.yield(request) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    private static func deliver(_ request: GhosttyDesktopNotificationRequest) async {
        guard let appDelegate = AppDelegate.shared,
              let target = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: request.tabId,
                surfaceId: request.surfaceId
              ),
              let owningManager = appDelegate.tabManagerFor(tabId: target.tabId) ?? appDelegate.tabManager else {
            return
        }
        let workspace = owningManager.workspacesById[target.tabId]
        await TerminalNotificationStore.shared.addDesktopNotificationResolvingHooks(
            tabId: request.tabId,
            surfaceId: request.surfaceId,
            hookDirectory: workspace?.isRemoteWorkspace == true ? nil : request.hookDirectory,
            title: request.title,
            body: request.body
        )
    }
}
