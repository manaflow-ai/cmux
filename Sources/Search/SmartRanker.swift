import Foundation

/// Re-ranks search hits using BM25 (already provided by FTS5) plus
/// recency boost and a Thompson-sampled click-history prior per panel.
///
/// State lives in `~/Library/Application Support/cmux/search-clicks.json`
/// — small enough to keep in memory, persisted on every accept.
@MainActor
public final class SmartRanker {
    public static let shared = SmartRanker()

    private struct ClickStat: Codable {
        var hits: Int = 1
        var picks: Int = 1
    }

    private var stats: [String: ClickStat] = [:]
    private let storeURL: URL

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storeURL = base.appending(path: "cmux/search-clicks.json")
        load()
    }

    public func rank(_ hits: [SearchIndex.Hit]) -> [SearchIndex.Hit] {
        let now = Date().timeIntervalSince1970
        return hits
            .map { hit -> (SearchIndex.Hit, Double) in
                // BM25 in `hit.rank` is "lower is better" — invert so we can add.
                let bm25 = 1.0 / (1.0 + max(0, hit.rank))
                let recency = recencyBoost(hit: hit, now: now)
                let prior = thompson(for: key(hit))
                return (hit, bm25 + 0.35 * recency + 0.25 * prior)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// Called when user accepts a hit. Updates the click prior.
    public func reward(_ hit: SearchIndex.Hit) {
        let k = key(hit)
        var s = stats[k] ?? ClickStat()
        s.picks += 1
        s.hits += 1
        stats[k] = s
        bumpExposure(otherHitKeys: [])  // exposure already counted on impress
        save()
    }

    /// Called once per impression for every visible hit (incl. the picked one).
    public func recordImpressions(_ hits: [SearchIndex.Hit]) {
        for h in hits {
            var s = stats[key(h)] ?? ClickStat()
            s.hits += 1
            stats[key(h)] = s
        }
        save()
    }

    // MARK: - internals

    private func key(_ h: SearchIndex.Hit) -> String {
        "\(h.kind.rawValue):\(h.panelID.uuidString)"
    }

    private func recencyBoost(hit: SearchIndex.Hit, now: TimeInterval) -> Double {
        // `SearchIndex` does not yet thread the timestamp into Hit;
        // until P4, rely on Thompson prior only. Hook stays so the
        // formula doesn't move when timestamp lands.
        return 0
    }

    private func thompson(for k: String) -> Double {
        let s = stats[k] ?? ClickStat()
        // Beta(picks, hits-picks+1) — mean is a deterministic stand-in
        // for actual sampling; we don't need exploration noise in a
        // UI ranker, just a stable prior. Range: ~0…1.
        return Double(s.picks) / Double(max(1, s.hits))
    }

    private func bumpExposure(otherHitKeys: [String]) {}

    private func load() {
        guard
            let data = try? Data(contentsOf: storeURL),
            let decoded = try? JSONDecoder().decode([String: ClickStat].self, from: data)
        else { return }
        stats = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
