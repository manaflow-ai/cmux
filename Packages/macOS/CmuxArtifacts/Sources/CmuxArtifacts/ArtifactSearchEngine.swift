import Foundation

/// Searches immutable tree values and bounded UTF-8 file contents.
struct ArtifactSearchEngine {
    let configuration: ArtifactCaptureConfiguration

    func results(snapshot: ArtifactSnapshot, query rawQuery: String) throws -> [ArtifactSearchResult] {
        try Task.checkCancellation()
        let matcher = ArtifactFuzzyMatcher(query: rawQuery)
        guard !matcher.isEmpty else { return [] }
        var remainingContentBytes = configuration.contentSearchTotalMaximumBytes
        var results: [ArtifactSearchResult] = []
        for node in snapshot.nodes.flattenedArtifactNodes() where !node.isDirectory {
            try Task.checkCancellation()
            let nameScore = matcher.score(candidate: node.name)
            let pathScore = matcher.score(candidate: node.relativePath).map { $0 - 250 }
            let contentMatch = try contentMatch(
                node: node,
                artifactsRoot: snapshot.artifactsRoot,
                query: matcher.contentQuery,
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
        try Task.checkCancellation()
        let sortedResults = results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.node.relativePath.localizedStandardCompare($1.node.relativePath) == .orderedAscending
        }
        try Task.checkCancellation()
        return sortedResults.prefix(configuration.maximumSearchResults).map { $0 }
    }

    private func contentMatch(
        node: ArtifactNode,
        artifactsRoot: URL,
        query: String,
        remainingBytes: inout Int64
    ) throws -> String? {
        try Task.checkCancellation()
        guard node.fileKind?.isTextSearchable == true, remainingBytes > 0 else {
            return nil
        }
        let maximumBytes = min(configuration.contentSearchMaximumBytes, remainingBytes)
        guard let data = try ArtifactBoundedFileReader().data(
            url: URL(fileURLWithPath: node.absolutePath),
            allowedRoot: artifactsRoot,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        try Task.checkCancellation()
        remainingBytes -= Int64(data.count)
        guard
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
