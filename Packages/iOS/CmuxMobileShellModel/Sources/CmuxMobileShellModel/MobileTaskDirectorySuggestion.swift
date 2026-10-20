public import Foundation

/// The context that made a directory useful to the task composer.
public enum MobileTaskDirectorySource: Int, CaseIterable, Hashable, Sendable {
    case home
    case filesystemSearch
    case recentSuccessful
    case openTerminal
    case openWorkspace
    case lastSuccessful
    case templateDefault
    case activeWorkspace
    case activeTerminal
}

/// Exact UTF-8 identity for a Mac path. Swift `String` equality intentionally
/// treats canonically equivalent Unicode as equal, while remote filesystem
/// paths must preserve the exact bytes reported by the Mac.
public struct MobileTaskDirectoryPathID: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(path: String) {
        bytes = Array(path.utf8)
    }
}

/// One directory fact available to the composer before matching and ranking.
public struct MobileTaskDirectoryCandidate: Identifiable, Equatable, Sendable {
    public let path: String
    public private(set) var sources: Set<MobileTaskDirectorySource>
    public private(set) var context: String?
    public private(set) var lastUsedAt: Date?
    public private(set) var useCount: Int

    public var id: MobileTaskDirectoryPathID {
        MobileTaskDirectoryPathID(path: path)
    }

    public var bestSource: MobileTaskDirectorySource {
        sources.max(by: { $0.rawValue < $1.rawValue }) ?? .home
    }

    public init(
        path: String,
        source: MobileTaskDirectorySource,
        context: String?,
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.path = path
        self.sources = [source]
        self.context = context
        self.lastUsedAt = lastUsedAt
        self.useCount = max(0, useCount)
    }

    mutating func merge(_ other: Self) {
        let previousPriority = bestSource.rawValue
        sources.formUnion(other.sources)
        if other.bestSource.rawValue > previousPriority, let context = other.context {
            self.context = context
        } else if context == nil {
            context = other.context
        }
        if let otherDate = other.lastUsedAt {
            if let currentDate = lastUsedAt {
                lastUsedAt = max(currentDate, otherDate)
            } else {
                lastUsedAt = otherDate
            }
        }
        useCount = max(useCount, other.useCount)
    }
}

/// One successful directory selection retained for per-Mac ordering.
public struct MobileTaskRecentDirectory: Codable, Equatable, Sendable {
    public let path: String
    public var lastUsedAt: Date
    public var useCount: Int

    public init(path: String, lastUsedAt: Date, useCount: Int) {
        self.path = path
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }
}

/// A prepared, immutable directory index. Candidate folding and component
/// parsing happen once; each keystroke performs one bounded scan and keeps only
/// the requested top results instead of sorting every match.
public struct MobileTaskDirectorySuggestionIndex: Sendable {
    private struct PreparedCandidate: Sendable {
        let candidate: MobileTaskDirectoryCandidate
        let foldedPath: String
        let foldedBasename: String
        let foldedComponents: [String]
    }

    private struct RankedCandidate {
        let prepared: PreparedCandidate
        let matchTier: Int
        let unmatchedComponents: Int
        let recency: Int
    }

    private let candidates: [PreparedCandidate]
    private let now: Date

    public init(candidates rawCandidates: [MobileTaskDirectoryCandidate], now: Date = Date()) {
        var merged: [MobileTaskDirectoryPathID: MobileTaskDirectoryCandidate] = [:]
        var insertionOrder: [MobileTaskDirectoryPathID] = []
        for candidate in rawCandidates where !candidate.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if var existing = merged[candidate.id] {
                existing.merge(candidate)
                merged[candidate.id] = existing
            } else {
                merged[candidate.id] = candidate
                insertionOrder.append(candidate.id)
            }
        }
        candidates = insertionOrder.compactMap { id in
            guard let candidate = merged[id] else { return nil }
            let foldedPath = Self.fold(candidate.path)
            let components = Self.components(foldedPath)
            return PreparedCandidate(
                candidate: candidate,
                foldedPath: foldedPath,
                foldedBasename: components.last ?? foldedPath,
                foldedComponents: components
            )
        }
        self.now = now
    }

    public func suggestions(
        matching query: String,
        limit: Int = 8
    ) -> [MobileTaskDirectoryCandidate] {
        guard limit > 0 else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = Self.fold(trimmedQuery)
        let queryComponents = Self.components(foldedQuery)
        let queryBasename = queryComponents.last ?? foldedQuery
        var top: [RankedCandidate] = []
        top.reserveCapacity(min(limit, candidates.count))

        for candidate in candidates {
            guard let match = match(
                candidate,
                rawQuery: trimmedQuery,
                foldedQuery: foldedQuery,
                queryBasename: queryBasename,
                queryComponents: queryComponents
            ) else { continue }
            let ranked = RankedCandidate(
                prepared: candidate,
                matchTier: match.tier,
                unmatchedComponents: match.unmatchedComponents,
                recency: recencyBucket(candidate.candidate.lastUsedAt)
            )
            let insertionIndex = top.firstIndex { isBetter(ranked, than: $0) } ?? top.endIndex
            top.insert(ranked, at: insertionIndex)
            if top.count > limit {
                top.removeLast()
            }
        }
        return top.map(\.prepared.candidate)
    }

    private func match(
        _ candidate: PreparedCandidate,
        rawQuery: String,
        foldedQuery: String,
        queryBasename: String,
        queryComponents: [String]
    ) -> (tier: Int, unmatchedComponents: Int)? {
        guard !foldedQuery.isEmpty else {
            return (tier: 0, unmatchedComponents: candidate.foldedComponents.count)
        }
        if candidate.candidate.id == MobileTaskDirectoryPathID(path: rawQuery) {
            return (tier: 5, unmatchedComponents: 0)
        }
        if candidate.candidate.path.hasPrefix(rawQuery) {
            return (tier: 4, unmatchedComponents: max(0, candidate.foldedComponents.count - queryComponents.count))
        }
        if candidate.foldedBasename == queryBasename {
            return (tier: 4, unmatchedComponents: max(0, candidate.foldedComponents.count - queryComponents.count))
        }
        if candidate.foldedPath.hasPrefix(foldedQuery) {
            return (tier: 3, unmatchedComponents: max(0, candidate.foldedComponents.count - queryComponents.count))
        }
        if Self.matchesOrderedComponentPrefixes(queryComponents, in: candidate.foldedComponents) {
            return (tier: 2, unmatchedComponents: max(0, candidate.foldedComponents.count - queryComponents.count))
        }
        if candidate.foldedBasename.contains(queryBasename)
            || candidate.foldedPath.contains(foldedQuery)
            || Self.hasFuzzyComponent(queryBasename, in: candidate.foldedComponents) {
            return (tier: 1, unmatchedComponents: max(0, candidate.foldedComponents.count - queryComponents.count))
        }
        return nil
    }

    private func isBetter(_ lhs: RankedCandidate, than rhs: RankedCandidate) -> Bool {
        if lhs.matchTier != rhs.matchTier { return lhs.matchTier > rhs.matchTier }
        let lhsSource = lhs.prepared.candidate.bestSource.rawValue
        let rhsSource = rhs.prepared.candidate.bestSource.rawValue
        if lhsSource != rhsSource { return lhsSource > rhsSource }
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        let lhsUsage = min(lhs.prepared.candidate.useCount, 99)
        let rhsUsage = min(rhs.prepared.candidate.useCount, 99)
        if lhsUsage != rhsUsage { return lhsUsage > rhsUsage }
        if lhs.unmatchedComponents != rhs.unmatchedComponents {
            return lhs.unmatchedComponents < rhs.unmatchedComponents
        }
        let lhsBytes = lhs.prepared.candidate.id.bytes
        let rhsBytes = rhs.prepared.candidate.id.bytes
        if lhsBytes.count != rhsBytes.count { return lhsBytes.count < rhsBytes.count }
        return lhsBytes.lexicographicallyPrecedes(rhsBytes)
    }

    private func recencyBucket(_ date: Date?) -> Int {
        guard let date else { return 0 }
        let age = max(0, now.timeIntervalSince(date))
        switch age {
        case ..<3_600: return 99
        case ..<86_400: return 80
        case ..<(7 * 86_400): return 60
        case ..<(30 * 86_400): return 40
        default: return 20
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func components(_ value: String) -> [String] {
        value.split { $0 == "/" || $0.isWhitespace }.map(String.init)
    }

    private static func matchesOrderedComponentPrefixes(
        _ query: [String],
        in candidate: [String]
    ) -> Bool {
        guard !query.isEmpty else { return false }
        var candidateIndex = candidate.startIndex
        for queryComponent in query {
            guard let match = candidate[candidateIndex...].firstIndex(where: { $0.hasPrefix(queryComponent) }) else {
                return false
            }
            candidateIndex = candidate.index(after: match)
        }
        return true
    }

    private static func hasFuzzyComponent(_ query: String, in components: [String]) -> Bool {
        guard query.count >= 3 else { return false }
        let maximum = query.count >= 7 ? 2 : 1
        return components.contains { component in
            abs(component.count - query.count) <= maximum
                && editDistance(component, query, maximum: maximum) <= maximum
        }
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= maximum else { return maximum + 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > maximum { return maximum + 1 }
            previous = current
        }
        return previous.last ?? maximum + 1
    }
}
