import Foundation

/// Fetches a usage snapshot for one provider account.
///
/// Adapters are `Sendable` and hold no mutable state; the freshness/rotation
/// invariant is a package-wide contract: an adapter **never writes or refreshes a
/// credential**. It reads whatever the provider CLI last persisted (read-only) and
/// calls the provider's own usage endpoint, or shells out to a CLI usage command.
public protocol ProviderUsageAdapter: Sendable {
    var provider: UsageProvider { get }
    func fetchUsage() async throws -> UsageSnapshot
}

/// Shared HTTP ceiling so a hostile/oversized response can't exhaust memory
/// (Temper F-T3: all network bodies are untrusted input).
enum UsageHTTP {
    /// Reject any usage response larger than this before decoding.
    static let maxResponseBytes = 256 * 1024
}
