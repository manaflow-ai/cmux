import Foundation

// release-attached-view-size, set-size-counts and detach-attached-view are generated
// (bindings.json, family TerminalIO).

/// Sets the terminal's own sizing policy (`set-size-policy {surface, policy}`, `shared-sizing-v1`).
/// Take over under a policy that picks by size sets last active first, so its claim wins
/// (plans/cmux-next/sync-ux/DESIGN.md 2.6).
public struct SetSizePolicyRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public struct Policy: Encodable, Sendable, Equatable {
        /// `latest`, `smallest`, `largest`, `priority` or `fixed`.
        public var mode: String
        public init(mode: String) { self.mode = mode }
    }
    public static let command = "set-size-policy"
    public var surface: SurfaceID
    public var policy: Policy
    public init(surface: SurfaceID, policy: Policy) {
        self.surface = surface
        self.policy = policy
    }
}
