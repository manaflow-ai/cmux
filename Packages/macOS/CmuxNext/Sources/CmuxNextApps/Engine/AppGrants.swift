import Synchronization

/// What an app may do right now: its granted scopes and whether it runs
/// sandboxed. Shared between the registry (writer) and the app's engine
/// (reader, once per call), so revoking a scope or switching the sandbox
/// takes effect on the next call without a reload (Lawrence 2026-10-02).
public nonisolated final class AppGrants: Sendable {
    public struct Snapshot: Sendable, Hashable {
        public var scopes: Set<String>
        /// No network, no integrations, nothing beyond explicit grants.
        public var sandboxed: Bool

        public init(scopes: Set<String>, sandboxed: Bool = false) {
            self.scopes = scopes
            self.sandboxed = sandboxed
        }
    }

    private let state: Mutex<Snapshot>

    public init(_ snapshot: Snapshot) {
        state = Mutex(snapshot)
    }

    public var snapshot: Snapshot { state.withLock { $0 } }

    public func update(_ snapshot: Snapshot) { state.withLock { $0 = snapshot } }
}
