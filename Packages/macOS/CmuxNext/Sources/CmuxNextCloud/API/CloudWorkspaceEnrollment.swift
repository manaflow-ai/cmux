public import Foundation

/// Owner attachments to the same workspace share provisioning and reconnect. The run lasts only
/// until the network operation and fresh daemon handshake finish; failed runs may be retried.
@MainActor
public final class CloudWorkspaceEnrollment {
    private struct Key: Hashable {
        let scope: CloudWorkspaceBindings.Scope
        let workspace: String
        let machine: String
    }
    private var runs: [Key: Task<Void, any Error>] = [:]
    /// Observes a join without changing its result (used by concurrency tests).
    var joined: () -> Void = {}

    public init() {}

    public func run(scope: CloudWorkspaceBindings.Scope, workspace: String, machine: String,
                    action: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        let key = Key(scope: scope, workspace: workspace, machine: machine)
        if let running = runs[key] {
            joined()
            try await running.value
        } else {
            // task-owner: one bounded enrollment per scope; removed on completion or failure.
            // A cancelled attachment cannot cancel provisioning that another attachment joined.
            let task = Task { @MainActor in try await action() }
            runs[key] = task
            defer { runs[key] = nil }
            try await task.value
        }
        try Task.checkCancellation()
    }
}
