public import Foundation

/// Delivers the first reconciled workspace for one mirror attachment without polling.
@MainActor
public final class HiveMirrorWorkspaceReadiness {
    private let ready = AsyncStream<UUID?>.makeStream(bufferingPolicy: .bufferingNewest(1))

    /// Creates the one-shot readiness channel owned by a mirror attachment.
    public init() {}

    /// Publishes a workspace only after reconciliation has installed it locally.
    /// - Parameter workspaceID: The ready local workspace, or nil to clear an obsolete snapshot.
    public func publish(_ workspaceID: UUID?) {
        ready.continuation.yield(workspaceID)
    }

    /// Ends the pending wait when its mirror is torn down.
    public func finish() { ready.continuation.finish() }

    /// Waits for a reconciled workspace, teardown, cancellation, or an injected deadline.
    /// - Parameter timeout: A cancellable deadline; tests control it without wall-clock sleeps.
    /// - Returns: A ready workspace identity, or nil when the attachment ends first.
    public func wait(timeout: @escaping @Sendable () async -> Void) async -> UUID? {
        let stream = ready.stream
        return await withTaskGroup(of: UUID?.self) { group in
            group.addTask {
                for await workspaceID in stream {
                    if let workspaceID { return workspaceID }
                }
                return nil
            }
            group.addTask {
                await timeout()
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}
