public import Foundation

/// Maps a provider to its default-configured adapter. Providers without a usable
/// usage surface (Gemini's unlimited tier, Kimi pending) return `nil` for now.
public enum UsageProviderRegistry {
    public static func adapter(for provider: UsageProvider) -> (any ProviderUsageAdapter)? {
        switch provider {
        case .codex: return CodexUsageAdapter()
        case .claude: return ClaudeUsageAdapter()
        case .grok: return GrokUsageAdapter()
        case .gemini, .kimi: return nil
        }
    }

    /// Providers that currently expose a usable live gauge.
    public static let gaugeable: [UsageProvider] = [.claude, .codex, .grok]
}

/// Orchestrates one on-demand fetch per provider, mapping adapter errors to a
/// `UsageSnapshot` with the appropriate `UsageFreshness` (never throws to the UI).
public struct UsageFetcher: Sendable {
    private let adapterFor: @Sendable (UsageProvider) -> (any ProviderUsageAdapter)?
    private let now: @Sendable () -> Date

    public init(
        adapterFor: @escaping @Sendable (UsageProvider) -> (any ProviderUsageAdapter)? = {
            UsageProviderRegistry.adapter(for: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapterFor = adapterFor
        self.now = now
    }

    /// Fetch one provider. Returns a snapshot whose `freshness` encodes success or the
    /// failure reason; `lastKnown` (if any) is preserved on a soft failure.
    public func fetch(_ provider: UsageProvider, lastKnown: UsageSnapshot? = nil) async -> UsageSnapshot {
        guard let adapter = adapterFor(provider) else {
            return unsupported(provider)
        }
        do {
            return try await adapter.fetchUsage()
        } catch let error as UsageAdapterError {
            return degraded(provider, error: error, lastKnown: lastKnown)
        } catch is CancellationError {
            return lastKnown ?? unsupported(provider)
        } catch {
            return degraded(provider, error: .malformedResponse, lastKnown: lastKnown)
        }
    }

    private func degraded(_ provider: UsageProvider, error: UsageAdapterError, lastKnown: UsageSnapshot?) -> UsageSnapshot {
        let freshness: UsageFreshness
        switch error {
        case .signedOut: freshness = .signedOut
        case .notInstalled: freshness = .notInstalled
        case .unsupported: freshness = .unsupported
        case .rateLimited: freshness = .rateLimited(until: now().addingTimeInterval(30 * 60))
        case .httpStatus, .malformedResponse: freshness = .stale(since: lastKnown?.fetchedAt)
        }
        return UsageSnapshot(
            account: lastKnown?.account ?? ProviderAccount(provider: provider, accountId: "default"),
            planLabel: lastKnown?.planLabel,
            windows: lastKnown?.windows ?? [],
            freshness: freshness,
            fetchedAt: now()
        )
    }

    private func unsupported(_ provider: UsageProvider) -> UsageSnapshot {
        UsageSnapshot(
            account: ProviderAccount(provider: provider, accountId: "default"),
            windows: [],
            freshness: .unsupported,
            fetchedAt: now()
        )
    }
}
