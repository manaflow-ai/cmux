import Foundation
import Testing
@testable import CmuxUsage

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

private struct FakeAdapter: ProviderUsageAdapter {
    let provider: UsageProvider
    let counter: CallCounter
    let result: Result<UsageSnapshot, UsageAdapterError>

    func fetchUsage() async throws -> UsageSnapshot {
        await counter.bump()
        switch result {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }
}

private func sampleSnapshot(_ provider: UsageProvider) -> UsageSnapshot {
    UsageSnapshot(
        account: ProviderAccount(provider: provider, accountId: "acct"),
        windows: [UsageWindow(kind: .rolling(seconds: 18000), usedPercent: 42)],
        freshness: .live(Date(timeIntervalSince1970: 0)),
        fetchedAt: Date(timeIntervalSince1970: 0)
    )
}

struct UsageFetcherTests {
    @Test func mapsSuccessThrough() async {
        let counter = CallCounter()
        let fetcher = UsageFetcher(adapterFor: { p in
            FakeAdapter(provider: p, counter: counter, result: .success(sampleSnapshot(p)))
        })
        let snap = await fetcher.fetch(.codex)
        #expect(snap.windows.first?.usedPercent == 42)
        if case .live = snap.freshness {} else { Issue.record("expected live") }
    }

    @Test func mapsSignedOutError() async {
        let counter = CallCounter()
        let fetcher = UsageFetcher(adapterFor: { p in
            FakeAdapter(provider: p, counter: counter, result: .failure(.signedOut))
        })
        let snap = await fetcher.fetch(.claude)
        #expect(snap.freshness == .signedOut)
    }

    @Test func mapsRateLimitedWithUntil() async {
        let now = Date(timeIntervalSince1970: 1000)
        let counter = CallCounter()
        let fetcher = UsageFetcher(
            adapterFor: { p in FakeAdapter(provider: p, counter: counter, result: .failure(.rateLimited)) },
            now: { now }
        )
        let snap = await fetcher.fetch(.grok)
        #expect(snap.freshness == .rateLimited(until: now.addingTimeInterval(1800)))
    }

    @Test func unsupportedProviderReturnsUnsupported() async {
        let snap = await UsageFetcher().fetch(.gemini)   // no adapter registered
        #expect(snap.freshness == .unsupported)
    }

    @Test func softFailurePreservesLastKnownWindows() async {
        let counter = CallCounter()
        let fetcher = UsageFetcher(adapterFor: { p in
            FakeAdapter(provider: p, counter: counter, result: .failure(.malformedResponse))
        })
        let previous = sampleSnapshot(.codex)
        let snap = await fetcher.fetch(.codex, lastKnown: previous)
        #expect(snap.windows.first?.usedPercent == 42)   // preserved
        if case .stale = snap.freshness {} else { Issue.record("expected stale") }
    }
}

@MainActor
struct UsageStoreTests {
    @Test func cachesWithinMinInterval() async {
        let now = Date(timeIntervalSince1970: 5000)
        let counter = CallCounter()
        let fetcher = UsageFetcher(
            adapterFor: { p in FakeAdapter(provider: p, counter: counter, result: .success(sampleSnapshot(p))) },
            now: { now }
        )
        let store = UsageStore(fetcher: fetcher, minInterval: 30, now: { now })

        await store.refresh(.codex)
        await store.refresh(.codex)   // within interval → skipped
        #expect(await counter.count == 1)
        #expect(store.snapshot(for: .codex)?.windows.first?.usedPercent == 42)

        await store.refresh(.codex, force: true)   // force bypasses interval
        #expect(await counter.count == 2)
    }

    @Test func honorsRateLimitedUntilBeyondMinInterval() async {
        let now = Date(timeIntervalSince1970: 5000)
        let counter = CallCounter()
        // Adapter throws rateLimited → fetcher maps to .rateLimited(until: now + 1800s).
        let fetcher = UsageFetcher(
            adapterFor: { p in FakeAdapter(provider: p, counter: counter, result: .failure(.rateLimited)) },
            now: { now }
        )
        // minInterval 0 so the ONLY thing that can block the 2nd refresh is the
        // rateLimited(until:) fence — proving the store honors it, not just minInterval.
        let store = UsageStore(fetcher: fetcher, minInterval: 0, now: { now })

        await store.refresh(.codex)
        #expect(await counter.count == 1)
        if case .rateLimited = store.snapshot(for: .codex)?.freshness {} else {
            Issue.record("expected rateLimited snapshot")
        }
        await store.refresh(.codex)   // blocked by `until`, not re-poked
        #expect(await counter.count == 1)
        await store.refresh(.codex, force: true)   // force still overrides
        #expect(await counter.count == 2)
    }

    @Test func cancelledFetchDoesNotPolluteSnapshotOrBlockRetry() async {
        let now = Date(timeIntervalSince1970: 5000)
        let counter = CallCounter()
        let fetcher = UsageFetcher(
            adapterFor: { p in FakeAdapter(provider: p, counter: counter, result: .success(sampleSnapshot(p))) },
            now: { now }
        )
        // Large minInterval: if a cancelled attempt wrongly counted, the retry below
        // would be blocked and the snapshot would stay nil / stale.
        let store = UsageStore(fetcher: fetcher, minInterval: 9999, now: { now })

        let task = Task { await store.refresh(.codex) }
        task.cancel()   // flag set before the MainActor task body can run
        await task.value

        // Cancelled fetch must not have written a snapshot…
        #expect(store.snapshot(for: .codex) == nil)
        // …and must not have consumed the min-interval budget: a real refresh succeeds.
        await store.refresh(.codex)
        #expect(store.snapshot(for: .codex)?.windows.first?.usedPercent == 42)
    }
}
