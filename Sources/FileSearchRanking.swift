import Foundation

enum FileSearchRanking {
    /// Stable re-rank of arrival-order ripgrep results into:
    /// 1) files whose basename stem equals the query (`game` → `Game.ts`),
    /// 2) files whose basename contains the query (`game` → `gamepiece.tsx`),
    /// 3) everything else.
    /// Within each tier, files sort alphabetically by relative path; within
    /// each file, hits sort by line number.
    static func apply(to results: [FileSearchResult], query: String) -> [FileSearchResult] {
        guard results.count > 1 else { return results }
        let lowerQuery = query.lowercased()
        guard !lowerQuery.isEmpty else { return results }

        // collapse the previous three [String:_] sidecars into one
        // dictionary of value-typed records. One hash lookup per result vs
        // three, and a single allocation for the per-path metadata.
        struct Entry {
            var tier: Int
            var lower: String
            var hits: [FileSearchResult]
        }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(results.count)
        var insertionOrder: [String] = []
        insertionOrder.reserveCapacity(results.count)

        for result in results {
            let path = result.relativePath
            if entries[path] != nil {
                entries[path]!.hits.append(result)
                continue
            }
            let basename = (path as NSString).lastPathComponent
            let stem = (basename as NSString).deletingPathExtension
            let basenameLower = basename.lowercased()
            let stemLower = stem.lowercased()
            let tier: Int
            if stemLower == lowerQuery {
                tier = 0
            } else if basenameLower.contains(lowerQuery) {
                tier = 1
            } else {
                tier = 2
            }
            entries[path] = Entry(tier: tier, lower: path.lowercased(), hits: [result])
            insertionOrder.append(path)
        }

        let sortedKeys = insertionOrder.sorted { lhs, rhs in
            // Force-unwrap: every key in `insertionOrder` was just inserted
            // into `entries` above. Avoids two optional unwraps per compare.
            let lhsEntry = entries[lhs]!
            let rhsEntry = entries[rhs]!
            if lhsEntry.tier != rhsEntry.tier { return lhsEntry.tier < rhsEntry.tier }
            // Already-lowercased keys: plain `<` is byte-order alphabetical and
            // ~10× faster than `localizedCaseInsensitiveCompare`. Stable across
            // identical lowercase forms because `sorted` is stable in Swift.
            return lhsEntry.lower < rhsEntry.lower
        }

        var ranked: [FileSearchResult] = []
        ranked.reserveCapacity(results.count)
        for key in sortedKeys {
            let hits = entries[key]!.hits
            // Common case: rg's per-file output is already line-ordered, so
            // a single linear scan to confirm avoids a sort allocation.
            if isLineSorted(hits) {
                ranked.append(contentsOf: hits)
            } else {
                ranked.append(contentsOf: hits.sorted { $0.lineNumber < $1.lineNumber })
            }
        }
        return ranked
    }

    @inline(__always)
    private static func isLineSorted(_ hits: [FileSearchResult]) -> Bool {
        if hits.count <= 1 { return true }
        var previous = hits[0].lineNumber
        for i in 1..<hits.count {
            let current = hits[i].lineNumber
            if current < previous { return false }
            previous = current
        }
        return true
    }
}
