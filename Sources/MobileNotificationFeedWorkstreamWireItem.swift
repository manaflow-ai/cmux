import Foundation

/// Immutable JSON-ready workstream payload transferred to the frame-sizing worker.
/// Foundation JSON values are value-semantic here and never mutated after init.
nonisolated struct MobileNotificationFeedWorkstreamWireItem: @unchecked Sendable {
    let foundationPayload: [String: Any]
}
