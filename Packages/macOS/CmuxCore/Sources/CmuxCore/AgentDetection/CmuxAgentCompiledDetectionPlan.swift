import Foundation

/// Immutable, indexed execution plan shared by all evaluations of a snapshot.
struct CmuxAgentCompiledDetectionPlan: Sendable {
    struct ProcessMatch: Sendable {
        let entryIndex: Int
        let matcherIndex: Int
    }

    private struct MatcherPosition: Sendable {
        let entryIndex: Int
        let matcherIndex: Int
    }

    let entries: [CmuxAgentCompiledManifestEntry]
    private let entryIndexByID: [String: Int]
    private let matcherPositions: [MatcherPosition]
    private let matcherOrdinalsByProcessName: [String: [Int]]
    private let unindexedMatcherOrdinals: [Int]
    // Bundled catalogs avoid building a Set and sorting candidates per scan.
    // User catalogs can exceed one machine word, so the array index remains
    // available as a bounded fallback for larger catalogs.
    private let matcherBitmasksByProcessName: [String: UInt64]
    private let unindexedMatcherBitmask: UInt64

    init(entries sourceEntries: [CmuxAgentManifestEntry]) {
        // `sorted(by:)` is not stable, so retain the caller's order inside a
        // source tier while making user-authored entries authoritative.
        let orderedEntries = sourceEntries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.source != rhs.element.source {
                    return lhs.element.source == .user
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .map(CmuxAgentCompiledManifestEntry.init)
        self.entries = orderedEntries

        var entryIndexByID: [String: Int] = [:]
        var matcherPositions: [MatcherPosition] = []
        var ordinalsByName: [String: [Int]] = [:]
        var unindexedOrdinals: [Int] = []
        var bitmasksByName: [String: UInt64] = [:]
        var unindexedBitmask: UInt64 = 0
        for (entryIndex, entry) in orderedEntries.enumerated() {
            if entryIndexByID[entry.entry.manifest.id] == nil {
                entryIndexByID[entry.entry.manifest.id] = entryIndex
            }
            for (matcherIndex, compiledMatcher) in entry.processMatchers.enumerated() {
                let ordinal = matcherPositions.count
                matcherPositions.append(MatcherPosition(
                    entryIndex: entryIndex,
                    matcherIndex: matcherIndex
                ))
                let names = compiledMatcher.matcher.processNames
                if names.isEmpty {
                    unindexedOrdinals.append(ordinal)
                    if ordinal < UInt64.bitWidth {
                        unindexedBitmask |= UInt64(1) << UInt64(ordinal)
                    }
                } else {
                    var seenNames = Set<String>()
                    for name in names {
                        let key = Self.processNameKey(name)
                        guard seenNames.insert(key).inserted else { continue }
                        ordinalsByName[key, default: []].append(ordinal)
                        if ordinal < UInt64.bitWidth {
                            bitmasksByName[key, default: 0] |= UInt64(1) << UInt64(ordinal)
                        }
                    }
                }
            }
        }
        self.entryIndexByID = entryIndexByID
        self.matcherPositions = matcherPositions
        self.matcherOrdinalsByProcessName = ordinalsByName
        self.unindexedMatcherOrdinals = unindexedOrdinals
        self.matcherBitmasksByProcessName = bitmasksByName
        self.unindexedMatcherBitmask = unindexedBitmask
    }

    func entry(manifestID: String) -> CmuxAgentCompiledManifestEntry? {
        entryIndexByID[manifestID].map { entries[$0] }
    }

    func entry(at index: Int) -> CmuxAgentCompiledManifestEntry {
        entries[index]
    }

    /// Indexed identity matching for process scans that do not request a
    /// diagnostic trace.
    func firstProcessMatch(
        context: CmuxAgentProcessEvaluationContext
    ) -> ProcessMatch? {
        var evaluation = CmuxAgentProcessEvaluationState()
        if matcherPositions.count <= UInt64.bitWidth {
            var candidates = unindexedMatcherBitmask
            for basename in context.executableBasenames {
                candidates |= matcherBitmasksByProcessName[Self.processNameKey(basename)] ?? 0
            }
            while candidates != 0 {
                let ordinal = candidates.trailingZeroBitCount
                candidates &= candidates &- 1
                let position = matcherPositions[ordinal]
                let entry = entries[position.entryIndex]
                switch entry.processMatchers[position.matcherIndex].matches(
                    context,
                    evaluation: &evaluation
                ) {
                case .matched:
                    return ProcessMatch(
                        entryIndex: position.entryIndex,
                        matcherIndex: position.matcherIndex
                    )
                case .notMatched:
                    continue
                case .budgetExceeded:
                    return nil
                }
            }
            return nil
        }
        var candidateOrdinals = Set(unindexedMatcherOrdinals)
        for basename in context.executableBasenames {
            candidateOrdinals.formUnion(
                matcherOrdinalsByProcessName[Self.processNameKey(basename)] ?? []
            )
        }
        for ordinal in candidateOrdinals.sorted() {
            let position = matcherPositions[ordinal]
            let entry = entries[position.entryIndex]
            switch entry.processMatchers[position.matcherIndex].matches(
                context,
                evaluation: &evaluation
            ) {
            case .matched:
                return ProcessMatch(
                    entryIndex: position.entryIndex,
                    matcherIndex: position.matcherIndex
                )
            case .notMatched:
                continue
            case .budgetExceeded:
                return nil
            }
        }
        return nil
    }

    /// Full ordered matching used only by the pane diagnostic path.
    func firstProcessMatch(
        context: CmuxAgentProcessEvaluationContext,
        trace: inout [CmuxAgentRuleTrace]
    ) -> ProcessMatch? {
        var evaluation = CmuxAgentProcessEvaluationState()
        for (entryIndex, entry) in entries.enumerated() {
            for (matcherIndex, matcher) in entry.processMatchers.enumerated() {
                let outcome = matcher.matches(
                    context,
                    evaluation: &evaluation
                )
                trace.append(CmuxAgentRuleTrace(
                    manifestID: entry.entry.manifest.id,
                    phase: .process,
                    ruleID: matcher.matcher.id,
                    matched: outcome == .matched,
                    detail: outcome == .budgetExceeded
                        ? "process.budget-exceeded"
                        : (outcome == .matched ? "process.matched" : "process.not-matched")
                ))
                switch outcome {
                case .matched:
                    return ProcessMatch(entryIndex: entryIndex, matcherIndex: matcherIndex)
                case .notMatched:
                    continue
                case .budgetExceeded:
                    return nil
                }
            }
        }
        return nil
    }

    func firstMatcher(
        context: CmuxAgentProcessEvaluationContext,
        manifestID: String
    ) -> CmuxAgentProcessMatcher? {
        guard let entry = entry(manifestID: manifestID) else { return nil }
        var evaluation = CmuxAgentProcessEvaluationState()
        for matcher in entry.processMatchers {
            switch matcher.matches(
                context,
                evaluation: &evaluation
            ) {
            case .matched:
                return matcher.matcher
            case .notMatched:
                continue
            case .budgetExceeded:
                return nil
            }
        }
        return nil
    }

    private static func processNameKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
