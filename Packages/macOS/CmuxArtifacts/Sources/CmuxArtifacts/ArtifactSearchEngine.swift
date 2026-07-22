import Foundation

/// Searches immutable tree values and bounded UTF-8 file contents.
struct ArtifactSearchEngine {
    let configuration: ArtifactCaptureConfiguration

    func results(snapshot: ArtifactSnapshot, query rawQuery: String) -> [ArtifactSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matcher = ArtifactFuzzyMatcher()
        var remainingContentBytes = configuration.contentSearchTotalMaximumBytes
        var results: [ArtifactSearchResult] = []
        for node in snapshot.nodes.flattenedArtifactNodes() where !node.isDirectory {
            let nameScore = matcher.score(candidate: node.name, query: query)
            let pathScore = matcher.score(candidate: node.relativePath, query: query).map { $0 - 250 }
            let contentMatch = contentMatch(
                node: node,
                query: query,
                remainingBytes: &remainingContentBytes
            )
            guard nameScore != nil || pathScore != nil || contentMatch != nil else { continue }
            let bestScore = max(nameScore ?? Int.min, pathScore ?? Int.min, contentMatch == nil ? Int.min : 2_000)
            results.append(ArtifactSearchResult(
                node: node,
                score: bestScore,
                matchedContent: contentMatch != nil,
                snippet: contentMatch
            ))
        }
        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.node.relativePath.localizedStandardCompare($1.node.relativePath) == .orderedAscending
        }
        .prefix(configuration.maximumSearchResults)
        .map { $0 }
    }

    private func contentMatch(
        node: ArtifactNode,
        query: String,
        remainingBytes: inout Int64
    ) -> String? {
        guard node.fileKind?.isTextSearchable == true,
              let size = node.size,
              size <= configuration.contentSearchMaximumBytes,
              size <= remainingBytes else {
            return nil
        }
        remainingBytes -= size
        guard
              let data = try? Data(contentsOf: URL(fileURLWithPath: node.absolutePath), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return query }
        return String(line.prefix(180))
    }
}
