import Foundation

#if DEBUG
extension GlobalSearchCoordinator {
    /// Refreshes Global Search and returns a debug payload for scripted checks.
    func debugQuery(_ query: String) async -> (hits: [SearchIndexHit], searchMilliseconds: Double) {
        await refreshLiveIndex()
        let started = ContinuousClock.now
        let hits = await search(query: query)
        let elapsed = started.duration(to: .now).components
        return (hits, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    /// Encodes the debug query result for the v2 socket response.
    nonisolated static func debugQueryPayload(
        _ result: (hits: [SearchIndexHit], searchMilliseconds: Double)
    ) -> [String: Any] {
        [
            "search_ms": result.searchMilliseconds,
            "hits": result.hits.map { hit -> [String: Any] in
                [
                    "kind": hit.kind.rawValue,
                    "title": hit.title,
                    "location": hit.location,
                    "snippet": hit.snippet,
                    "panel_id": hit.panelID?.uuidString ?? "",
                ]
            },
        ]
    }
}
#endif
