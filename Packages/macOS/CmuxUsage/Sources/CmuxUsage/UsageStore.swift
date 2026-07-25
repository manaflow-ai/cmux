public import Foundation
public import Combine

/// On-demand usage cache the HUD observes. **No background timer** (Temper F-T4): callers
/// trigger `refresh` on explicit user action (panel open, active-provider change, tap).
/// Each provider is fetched at most once per `minInterval` and never concurrently.
@MainActor
public final class UsageStore: ObservableObject {
    /// Latest snapshot per provider. UI reads value copies only.
    @Published public private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]

    private let fetcher: UsageFetcher
    private let minInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: Set<UsageProvider> = []
    private var lastAttemptAt: [UsageProvider: Date] = [:]

    public init(
        fetcher: UsageFetcher = UsageFetcher(),
        minInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.minInterval = minInterval
        self.now = now
    }

    public func snapshot(for provider: UsageProvider) -> UsageSnapshot? {
        snapshots[provider]
    }

    /// Refresh one provider on demand. Skips if a fetch is in flight or the last attempt
    /// was within `minInterval` (unless `force`). Failures degrade the snapshot rather
    /// than throwing.
    public func refresh(_ provider: UsageProvider, force: Bool = false) async {
        guard !inFlight.contains(provider) else { return }
        if !force, let last = lastAttemptAt[provider],
           now().timeIntervalSince(last) < minInterval {
            return
        }
        inFlight.insert(provider)
        lastAttemptAt[provider] = now()
        defer { inFlight.remove(provider) }

        let snapshot = await fetcher.fetch(provider, lastKnown: snapshots[provider])
        snapshots[provider] = snapshot
    }

    /// Refresh several providers (e.g. when the panel opens). Each `refresh` awaits its
    /// network fetch, so the MainActor is free between suspensions and the fetches overlap.
    public func refresh(_ providers: [UsageProvider], force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { await self.refresh(provider, force: force) }
            }
        }
    }
}
