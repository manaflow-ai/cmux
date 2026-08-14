import Foundation

/// A pure rule engine. It does not read the filesystem, terminal, or process
/// table; callers provide immutable snapshots and can therefore reuse it from
/// scans, hooks, mobile mirrors, and tests.
public struct CmuxAgentDetectionEngine: Sendable {
    /// The entries supplied to this engine, in catalog order.
    public let entries: [CmuxAgentManifestEntry]
    private let orderedEntries: [CmuxAgentManifestEntry]

    /// Creates an engine over a validated manifest snapshot.
    ///
    /// - Parameter entries: Validated entries in deterministic catalog order.
    public init(entries: [CmuxAgentManifestEntry]) {
        self.entries = entries
        // `sorted(by:)` is not required to be stable. Preserve the caller's
        // order within each source tier so overlapping user manifests remain
        // deterministic across reloads and Swift toolchains.
        self.orderedEntries = entries.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.source != rhs.element.source {
                    return lhs.element.source == .user
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Finds the first manifest and matcher that identify `process`.
    ///
    /// - Parameters:
    ///   - process: Immutable process identity fields to evaluate.
    ///   - trace: Trace buffer to which each attempted matcher is appended.
    /// - Returns: The selected entry and matcher, or `nil` when none match.
    public func matchingEntry(
        for process: CmuxAgentProcessSnapshot,
        trace: inout [CmuxAgentRuleTrace]
    ) -> (entry: CmuxAgentManifestEntry, matcher: CmuxAgentProcessMatcher)? {
        for entry in matchingEntries {
            for matcher in entry.manifest.process.matchers {
                let match = matcherMatches(matcher, process: process)
                trace.append(CmuxAgentRuleTrace(
                    manifestID: entry.manifest.id,
                    phase: .process,
                    ruleID: matcher.id,
                    matched: match,
                    detail: match ? "process.matched" : "process.not-matched"
                ))
                if match { return (entry, matcher) }
            }
        }
        return nil
    }

    /// Identifies a process and evaluates its ordered screen/OSC state rules.
    ///
    /// - Parameters:
    ///   - process: Immutable process identity fields to evaluate.
    ///   - screen: Bounded active-screen text supplied by the caller.
    ///   - osc: Bounded OSC capture supplied by the caller.
    /// - Returns: The selected identity, state, provenance, and bounded trace.
    public func detect(
        process: CmuxAgentProcessSnapshot,
        screen: String = "",
        osc: String = ""
    ) -> CmuxAgentDetectionResult {
        var trace: [CmuxAgentRuleTrace] = []
        guard let match = matchingEntry(for: process, trace: &trace) else {
            return CmuxAgentDetectionResult(
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
        let state = classify(
            entry: match.entry,
            screen: screen,
            osc: osc,
            trace: &trace
        )
        return CmuxAgentDetectionResult(
            agentID: match.entry.manifest.id,
            displayName: match.entry.manifest.displayName,
            source: match.entry.source,
            sourcePath: match.entry.sourcePath,
            processMatcherID: match.matcher.id,
            classification: state.classification,
            stateRuleID: state.ruleID,
            trace: boundedTrace(trace)
        )
    }

    /// Evaluates the ordered state rules for one known manifest.
    ///
    /// This overload is useful when the caller already resolved process
    /// identity (for example, a hook payload carries its agent id) and wants
    /// the exact same state-rule source as a pane diagnostic. It deliberately
    /// does not infer an identity from the screen text.
    ///
    /// - Parameters:
    ///   - manifestID: The manifest identifier to evaluate.
    ///   - screen: The bounded screen or hook text snapshot.
    ///   - osc: The bounded OSC snapshot.
    /// - Returns: A diagnostic result, or an unknown result when the id is not
    ///   present in this engine.
    public func detect(
        manifestID: String,
        screen: String = "",
        osc: String = ""
    ) -> CmuxAgentDetectionResult {
        guard let entry = matchingEntry(manifestID: manifestID) else {
            return CmuxAgentDetectionResult(
                agentID: nil,
                displayName: nil,
                source: nil,
                sourcePath: nil,
                processMatcherID: nil,
                classification: .unknown,
                stateRuleID: nil,
                trace: []
            )
        }
        var trace: [CmuxAgentRuleTrace] = []
        let state = classify(entry: entry, screen: screen, osc: osc, trace: &trace)
        return CmuxAgentDetectionResult(
            agentID: entry.manifest.id,
            displayName: entry.manifest.displayName,
            source: entry.source,
            sourcePath: entry.sourcePath,
            processMatcherID: nil,
            classification: state.classification,
            stateRuleID: state.ruleID,
            trace: boundedTrace(trace)
        )
    }

    /// Evaluates state rules for a known manifest without process matching.
    ///
    /// - Parameters:
    ///   - manifestID: Identifier of the accepted manifest to evaluate.
    ///   - screen: Bounded active-screen text supplied by the caller.
    ///   - osc: Bounded OSC capture supplied by the caller.
    /// - Returns: The selected classification and state-rule identifier.
    public func classify(
        manifestID: String,
        screen: String = "",
        osc: String = ""
    ) -> (classification: CmuxAgentClassification, stateRuleID: String?) {
        guard let entry = matchingEntry(manifestID: manifestID) else {
            return (.unknown, nil)
        }
        var trace: [CmuxAgentRuleTrace] = []
        let result = classify(entry: entry, screen: screen, osc: osc, trace: &trace)
        return (classification: result.classification, stateRuleID: result.ruleID)
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
        let candidates = manifestID.map { id in matchingEntries.filter { $0.manifest.id == id } } ?? matchingEntries
        for entry in candidates {
            if let matcher = entry.manifest.process.matchers.first(where: { matcherMatches($0, process: process) }) {
                return matcher
            }
        }
        return nil
    }

    private func matchingEntry(manifestID: String) -> CmuxAgentManifestEntry? {
        matchingEntries.first { $0.manifest.id == manifestID }
    }

    /// User entries intentionally outrank bundled entries when a newly added
    /// manifest happens to match the same process as a built-in. Existing ids
    /// are already represented by a `.user` entry in place; this ordering makes
    /// the precedence explicit for new ids as well.
    private var matchingEntries: [CmuxAgentManifestEntry] {
        orderedEntries
    }

    private func classify(
        entry: CmuxAgentManifestEntry,
        screen: String,
        osc: String,
        trace: inout [CmuxAgentRuleTrace]
    ) -> (classification: CmuxAgentClassification, ruleID: String?) {
        let boundedScreen = Self.boundedInput(screen)
        let boundedOSC = Self.boundedInput(osc)
        for rule in entry.manifest.states {
            let containsMatch = rule.screenContains.enumerated().first { _, value in
                boundedScreen.range(of: value, options: [.caseInsensitive, .literal]) != nil
            }
            let regexMatch = rule.screenRegex.enumerated().first { _, pattern in
                var options: NSRegularExpression.Options = []
                if pattern.caseInsensitive { options.insert(.caseInsensitive) }
                if pattern.dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
                guard let regex = try? NSRegularExpression(pattern: pattern.pattern, options: options) else {
                    return false
                }
                let range = NSRange(boundedScreen.startIndex..<boundedScreen.endIndex, in: boundedScreen)
                return regex.firstMatch(in: boundedScreen, options: [], range: range) != nil
            }
            let oscMatch = rule.osc.enumerated().first { _, value in matches(value, in: boundedOSC) }
            let matched = containsMatch != nil || regexMatch != nil || oscMatch != nil
            let detail: String
            let conditionID: String?
            if let containsMatch {
                conditionID = "screenContains[\(containsMatch.offset)]"
                detail = "screen.contains"
            } else if let regexMatch {
                conditionID = "screenRegex[\(regexMatch.offset)]"
                detail = "screen.regex"
            } else if let oscMatch {
                conditionID = "osc[\(oscMatch.offset)]"
                detail = "osc.matched"
            } else {
                conditionID = nil
                detail = "state.not-matched"
            }
            trace.append(CmuxAgentRuleTrace(
                manifestID: entry.manifest.id,
                phase: .state,
                ruleID: rule.id,
                matched: matched,
                conditionID: conditionID,
                detail: detail
            ))
            if matched {
                return (CmuxAgentClassification(state: rule.state), rule.id)
            }
        }
        return (.unknown, nil)
    }

    private func matcherMatches(
        _ matcher: CmuxAgentProcessMatcher,
        process: CmuxAgentProcessSnapshot
    ) -> Bool {
        let namesMatch = matcher.processNames.isEmpty || matcher.processNames.contains { expected in
            process.executableBasenames.contains {
                $0.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
            }
        }
        guard namesMatch else { return false }
        if !matcher.processPathContains.isEmpty {
            guard let processPath = process.processPath else { return false }
            let normalizedPath = processPath.replacingOccurrences(of: "\\", with: "/")
            guard matcher.processPathContains.allSatisfy({ needle in
                normalizedPath.range(of: needle.replacingOccurrences(of: "\\", with: "/"), options: [.caseInsensitive, .literal]) != nil
            }) else { return false }
        }
        if !matcher.processPathRegex.isEmpty {
            guard let processPath = process.processPath else { return false }
            guard matcher.processPathRegex.contains(where: { pattern in
                var options: NSRegularExpression.Options = []
                if pattern.caseInsensitive { options.insert(.caseInsensitive) }
                if pattern.dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
                guard let regex = try? NSRegularExpression(pattern: pattern.pattern, options: options) else { return false }
                let range = NSRange(processPath.startIndex..<processPath.endIndex, in: processPath)
                return regex.firstMatch(in: processPath, options: [], range: range) != nil
            }) else { return false }
        }
        guard matcher.argvContainsAll.allSatisfy({ argumentContains(process.arguments, needle: $0) }) else {
            return false
        }
        if !matcher.argvContainsAny.isEmpty,
           !matcher.argvContainsAny.contains(where: { argumentContains(process.arguments, needle: $0) }) {
            return false
        }
        if !matcher.argvBasenamesAny.isEmpty,
           !basenameEntrypointMatches(process, expected: matcher.argvBasenamesAny) {
            return false
        }
        return matcher.environmentEquals.allSatisfy { key, expected in
            process.environment[key] == expected
        }
    }

    private func argumentContains(_ arguments: [String], needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if needle.contains(" ") {
            return arguments.joined(separator: " ").range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
        if needle.contains("/") {
            return arguments.joined(separator: "\u{0}").range(of: needle, options: [.caseInsensitive, .literal]) != nil
        }
        return arguments.contains { argument in
            argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                || (argument as NSString).lastPathComponent.range(
                    of: needle,
                    options: [.caseInsensitive, .literal]
                ) != nil
        }
    }

    private func basenameEntrypointMatches(
        _ process: CmuxAgentProcessSnapshot,
        expected: [String]
    ) -> Bool {
        guard !process.arguments.isEmpty else { return false }
        let names = expected.map { $0.lowercased() }
        if process.executableBasenames.contains(where: {
            ["python", "python3"].contains($0.lowercased())
        }) {
            guard let index = pythonEntrypointIndex(process.arguments) else { return false }
            return names.contains((process.arguments[index] as NSString).lastPathComponent.lowercased())
        }
        return process.arguments.contains { names.contains(($0 as NSString).lastPathComponent.lowercased()) }
    }

    private func pythonEntrypointIndex(_ arguments: [String]) -> Int? {
        var index = 0
        if index < arguments.count,
           ["python", "python3"].contains((arguments[index] as NSString).lastPathComponent.lowercased()) {
            index += 1
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? index + 1 : nil }
            if argument == "-" { return nil }
            if argument == "-m" { return index + 1 < arguments.count ? index + 1 : nil }
            if ["-c", "-h", "--help", "-V", "--version"].contains(argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument) {
                return nil
            }
            if argument.hasPrefix("-") {
                let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
                index += 1 + (["-W", "-X", "--check-hash-based-pycs"].contains(option) && !argument.contains("=") ? 1 : 0)
                continue
            }
            return index
        }
        return nil
    }

    private func matches(_ rule: CmuxAgentOSCSequenceRule, in value: String) -> Bool {
        let sequence = canonicalOSCIntroducer(rule.sequence)
        let candidate = canonicalOSCIntroducer(value)
        switch rule.mode {
        case .contains: return candidate.range(of: sequence, options: [.literal]) != nil
        case .prefix: return candidate.hasPrefix(sequence)
        case .exact: return candidate == sequence
        }
    }

    private func canonicalOSCIntroducer(_ value: String) -> String {
        // OSC may arrive as either the seven-bit `ESC ]` introducer or the C1
        // `0x9d` byte. Normalize every C1 introducer, not only a leading one,
        // so a captured stream containing preceding terminal text still
        // compares with a manifest sequence deterministically.
        var result = ""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            if scalar.value == 0x9D {
                result.append("\u{1B}]")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func boundedTrace(_ trace: [CmuxAgentRuleTrace]) -> [CmuxAgentRuleTrace] {
        let limit = 256
        guard trace.count > limit else { return trace }
        let selectedTail = trace.enumerated().compactMap { index, entry in
            index >= limit && entry.matched ? entry : nil
        }
        guard !selectedTail.isEmpty else { return Array(trace.prefix(limit)) }
        let retainedMatches = Array(selectedTail.suffix(limit))
        return Array(trace.prefix(limit - retainedMatches.count)) + retainedMatches
    }

    private static func boundedInput(_ value: String) -> String {
        guard value.utf8.count > CmuxAgentManifestCodec.maximumScreenInputBytes else { return value }
        var result = ""
        result.reserveCapacity(CmuxAgentManifestCodec.maximumScreenInputBytes)
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= CmuxAgentManifestCodec.maximumScreenInputBytes else { break }
            result.append(character)
            bytes += count
        }
        return result
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
