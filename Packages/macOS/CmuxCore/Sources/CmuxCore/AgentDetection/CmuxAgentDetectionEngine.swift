import Foundation

/// A pure, immutable rule engine compiled once from a validated manifest
/// snapshot. It performs no filesystem, terminal, or process-table I/O.
public struct CmuxAgentDetectionEngine: Sendable {
    /// The entries supplied to this engine, in catalog order.
    public let entries: [CmuxAgentManifestEntry]
    private let plan: CmuxAgentCompiledDetectionPlan

    /// Creates a compiled engine over validated manifest entries.
    ///
    /// - Parameter entries: Validated entries in deterministic catalog order.
    public init(entries: [CmuxAgentManifestEntry]) {
        self.entries = entries
        self.plan = CmuxAgentCompiledDetectionPlan(entries: entries)
    }

    /// Finds the first manifest and matcher that identify `process` without
    /// allocating a diagnostic trace.
    ///
    /// Use this overload for process scanning. The trace overload is reserved
    /// for explicit diagnostics.
    ///
    /// - Parameter process: Immutable process identity fields to evaluate.
    /// - Returns: The selected entry and matcher, or `nil` when none match.
    public func matchingEntry(
        for process: CmuxAgentProcessSnapshot
    ) -> (entry: CmuxAgentManifestEntry, matcher: CmuxAgentProcessMatcher)? {
        let context = CmuxAgentProcessEvaluationContext(process: process)
        guard let match = plan.firstProcessMatch(context: context) else {
            return nil
        }
        return resolvedProcessMatch(match)
    }

    /// Finds the first manifest and matcher that identify `process`, appending
    /// each attempted matcher to `trace` for an explicit diagnostic request.
    ///
    /// - Parameters:
    ///   - process: Immutable process identity fields to evaluate.
    ///   - trace: Trace buffer receiving each attempted matcher.
    /// - Returns: The selected entry and matcher, or `nil` when none match.
    public func matchingEntry(
        for process: CmuxAgentProcessSnapshot,
        trace: inout [CmuxAgentRuleTrace]
    ) -> (entry: CmuxAgentManifestEntry, matcher: CmuxAgentProcessMatcher)? {
        let context = CmuxAgentProcessEvaluationContext(process: process)
        guard let match = plan.firstProcessMatch(
            context: context,
            trace: &trace
        ) else {
            return nil
        }
        return resolvedProcessMatch(match)
    }

    /// Identifies a process and evaluates its ordered screen/OSC state rules.
    ///
    /// - Parameters:
    ///   - process: Immutable process identity fields to evaluate.
    ///   - screen: Active-screen text supplied by the caller.
    ///   - osc: OSC capture supplied by the caller.
    /// - Returns: The selected identity, state, provenance, and bounded trace.
    public func detect(
        process: CmuxAgentProcessSnapshot,
        screen: String = "",
        osc: String = ""
    ) -> CmuxAgentDetectionResult {
        let context = CmuxAgentProcessEvaluationContext(process: process)
        var trace: [CmuxAgentRuleTrace] = []
        guard let match = plan.firstProcessMatch(
            context: context,
            trace: &trace
        ) else {
            return unknownResult(trace: trace)
        }
        let compiledEntry = plan.entry(at: match.entryIndex)
        let state = classify(
            entry: compiledEntry,
            screen: screen,
            osc: osc,
            includeTrace: true
        )
        trace.append(contentsOf: state.trace)
        let matcher = compiledEntry.processMatchers[match.matcherIndex].matcher
        return CmuxAgentDetectionResult(
            agentID: compiledEntry.entry.manifest.id,
            displayName: compiledEntry.entry.manifest.displayName,
            source: compiledEntry.entry.source,
            sourcePath: compiledEntry.entry.sourcePath,
            processMatcherID: matcher.id,
            classification: state.classification,
            stateRuleID: state.ruleID,
            trace: boundedTrace(trace)
        )
    }

    /// Evaluates state rules for a known manifest without process matching.
    ///
    /// - Parameters:
    ///   - manifestID: Identifier of the accepted manifest to evaluate.
    ///   - screen: Active-screen or hook text supplied by the caller.
    ///   - osc: OSC capture supplied by the caller.
    /// - Returns: A diagnostic result, or an unknown result for an absent id.
    public func detect(
        manifestID: String,
        screen: String = "",
        osc: String = ""
    ) -> CmuxAgentDetectionResult {
        guard let entry = plan.entry(manifestID: manifestID) else {
            return unknownResult(trace: [])
        }
        let state = classify(
            entry: entry,
            screen: screen,
            osc: osc,
            includeTrace: true
        )
        return CmuxAgentDetectionResult(
            agentID: entry.entry.manifest.id,
            displayName: entry.entry.manifest.displayName,
            source: entry.entry.source,
            sourcePath: entry.entry.sourcePath,
            processMatcherID: nil,
            classification: state.classification,
            stateRuleID: state.ruleID,
            trace: boundedTrace(state.trace)
        )
    }

    /// Evaluates state rules for a known manifest without constructing a trace.
    ///
    /// - Parameters:
    ///   - manifestID: Identifier of the accepted manifest to evaluate.
    ///   - screen: Active-screen or hook text supplied by the caller.
    ///   - osc: OSC capture supplied by the caller.
    /// - Returns: The selected classification and state-rule identifier.
    public func classify(
        manifestID: String,
        screen: String = "",
        osc: String = ""
    ) -> (classification: CmuxAgentClassification, stateRuleID: String?) {
        guard let entry = plan.entry(manifestID: manifestID) else {
            return (.unknown, nil)
        }
        let state = classify(
            entry: entry,
            screen: screen,
            osc: osc,
            includeTrace: false
        )
        return (state.classification, state.ruleID)
    }

    /// Returns the first matcher that accepts a process snapshot.
    ///
    /// - Parameters:
    ///   - process: Immutable process identity fields to evaluate.
    ///   - manifestID: Optional manifest id restricting the search.
    /// - Returns: The selected matcher, or `nil` when none match.
    public func matcher(
        for process: CmuxAgentProcessSnapshot,
        manifestID: String? = nil
    ) -> CmuxAgentProcessMatcher? {
        let context = CmuxAgentProcessEvaluationContext(process: process)
        if let manifestID {
            return plan.firstMatcher(
                context: context,
                manifestID: manifestID
            )
        }
        guard let match = plan.firstProcessMatch(context: context) else {
            return nil
        }
        return plan.entry(at: match.entryIndex).processMatchers[match.matcherIndex].matcher
    }

    private func resolvedProcessMatch(
        _ match: CmuxAgentCompiledDetectionPlan.ProcessMatch
    ) -> (entry: CmuxAgentManifestEntry, matcher: CmuxAgentProcessMatcher) {
        let entry = plan.entry(at: match.entryIndex)
        return (entry.entry, entry.processMatchers[match.matcherIndex].matcher)
    }

    private func classify(
        entry: CmuxAgentCompiledManifestEntry,
        screen: String,
        osc: String,
        includeTrace: Bool
    ) -> (
        classification: CmuxAgentClassification,
        ruleID: String?,
        trace: [CmuxAgentRuleTrace]
    ) {
        let boundedScreen = entry.hasScreenConditions
            ? Self.boundedNewestInput(screen)
            : ""
        let boundedOSC = entry.hasOSCConditions
            ? Self.boundedNewestInput(osc)
            : ""
        let canonicalOSC = entry.hasOSCConditions
            ? CmuxAgentCompiledStateRule.canonicalOSCIntroducer(boundedOSC)
            : ""
        let screenRange = entry.hasScreenRegexConditions
            ? NSRange(
                boundedScreen.startIndex..<boundedScreen.endIndex,
                in: boundedScreen
            )
            : NSRange(location: 0, length: 0)
        let searchableScreen = entry.hasScreenContainsConditions
            ? boundedScreen as NSString
            : "" as NSString
        let screenByteCount = boundedScreen.utf8.count
        var regexDeadline: CmuxAgentEvaluationDeadline?
        var workBudget = CmuxAgentEvaluationWorkBudget()
        var trace: [CmuxAgentRuleTrace] = []
        for rule in entry.stateRules {
            let match = rule.match(
                screen: boundedScreen,
                searchableScreen: searchableScreen,
                screenByteCount: screenByteCount,
                screenRange: screenRange,
                canonicalOSC: canonicalOSC,
                regexDeadline: &regexDeadline,
                workBudget: &workBudget
            )
            if includeTrace {
                trace.append(CmuxAgentRuleTrace(
                    manifestID: entry.entry.manifest.id,
                    phase: .state,
                    ruleID: rule.rule.id,
                    matched: match.outcome == .matched,
                    conditionID: match.conditionID,
                    detail: match.detail
                ))
            }
            switch match.outcome {
            case .matched:
                return (CmuxAgentClassification(state: rule.rule.state), rule.rule.id, trace)
            case .notMatched:
                continue
            case .budgetExceeded:
                return (.unknown, nil, trace)
            }
        }
        return (.unknown, nil, trace)
    }

    private func unknownResult(trace: [CmuxAgentRuleTrace]) -> CmuxAgentDetectionResult {
        CmuxAgentDetectionResult(
            agentID: nil,
            displayName: nil,
            source: nil,
            sourcePath: nil,
            processMatcherID: nil,
            classification: .unknown,
            stateRuleID: nil,
            trace: boundedTrace(trace)
        )
    }

    private func boundedTrace(_ trace: [CmuxAgentRuleTrace]) -> [CmuxAgentRuleTrace] {
        let limit = 256
        guard trace.count > limit else { return trace }
        let retainedMatches = Array(trace.dropFirst(limit).filter(\.matched).suffix(limit))
        return Array(trace.prefix(limit - retainedMatches.count)) + retainedMatches
    }

    private static func boundedNewestInput(_ value: String) -> String {
        let limit = CmuxAgentManifestCodec.maximumScreenInputBytes
        guard value.utf8.count > limit else { return value }
        // `String(decoding:)` repairs at most the leading partial scalar when
        // the byte window begins inside a multi-byte character.
        return String(decoding: value.utf8.suffix(limit), as: UTF8.self)
    }
}

private extension CmuxAgentClassification {
    init(state: CmuxAgentDetectionState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .blocked: self = .blocked
        case .permissionPrompt: self = .permissionPrompt
        case .done: self = .done
        }
    }
}
