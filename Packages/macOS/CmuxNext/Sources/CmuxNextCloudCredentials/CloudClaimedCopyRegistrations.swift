public import Foundation

/// Red stub: tracks no registration, so a start asks `wait-copy` before Rust has registered the claim's copy.
@MainActor public final class CloudClaimedCopyRegistrations {
    public init() {}

    func register<Answer: Sendable>(_ machine: String, _ register: @escaping @MainActor @Sendable () async -> Answer) -> Task<Answer, Never> {
        // task-owner: the returned task; it ends with the claim's one CLI call.
        Task { @MainActor in await register() }
    }

    public func registered(_ machine: String) async {}

    var pendingCount: Int { 0 }
}
