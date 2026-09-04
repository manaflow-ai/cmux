import Foundation

/// Incrementally detects provider-specific context-pressure markers in PTY output.
///
/// The detector owns ANSI/control-sequence normalization, chunk-boundary carry,
/// bounded carry, occurrence accounting, and event deduplication. Adding
/// a provider is a data change to ``ProviderDefinition`` rather than a new regex
/// branch in terminal rendering code.
public struct AgentContextPressureDetector: Sendable {
    private let provider: AgentContextProvider
    private let definition: AgentContextProviderDefinition
    private var normalizer = TerminalOutputNormalizer()
    private var markerCarry = ""
    private var percentageCarry = ""
    private var occurrences: [AgentContextPressureSignal: Int] = [:]
    private var detectedSignals: [AgentContextPressureSignal] = []
    /// Bounds range storage and sorting for one PTY chunk. Pressure thresholds
    /// are at most a few occurrences, so additional matches cannot affect the
    /// decision and are deliberately clipped to keep the hot path bounded.
    private static let maximumMarkerMatchesPerMarker = 128
    /// Bounds percentage-location deduplication for one provider pattern.
    /// Thresholds never need an unbounded number of footer observations.
    private static let maximumPercentageMatchesPerPattern = 128

    /// Creates a detector for one provider.
    ///
    /// - Parameter provider: The provider whose data-driven patterns should be evaluated.
    public init(provider: AgentContextProvider) {
        self.provider = provider
        self.definition = .definition(for: provider)
    }

    /// The current value snapshot.
    public var snapshot: AgentContextPressureSnapshot {
        AgentContextPressureSnapshot(
            isUnderPressure: !detectedSignals.isEmpty,
            detectedSignals: detectedSignals,
            occurrences: occurrences
        )
    }

    /// Feeds one arbitrary PTY output chunk and returns newly emitted events.
    ///
    /// - Parameter output: One decoded PTY output chunk; chunk boundaries may split markers.
    /// - Returns: Pressure events whose provider threshold was reached by this chunk.
    public mutating func consume(_ output: String) -> [AgentContextPressureEvent] {
        let normalized = normalizer.normalize(output)
        guard !normalized.isEmpty else { return [] }
        let combined = markerCarry + normalized
        let carryBoundary = combined.index(combined.startIndex, offsetBy: markerCarry.count)

        var newlyMatched: [AgentContextPressureSignal: Int] = [:]
        for pattern in definition.patterns {
            let markerRanges = pattern.markers.flatMap { marker in
                Self.newMatchRanges(
                    of: marker,
                    in: combined,
                    extendingPast: carryBoundary,
                    maximumMatches: Self.maximumMarkerMatchesPerMarker
                )
            }
            // Provider definitions intentionally allow broad and specific
            // alternatives. One rendered status line can therefore contain
            // overlapping markers (for example, "auto-compacting" and
            // "compacting conversation"). Treat overlapping ranges as one
            // provider event so thresholds count lifecycle events, not aliases.
            let matches = Self.distinctOccurrenceCount(in: markerRanges)
            if matches > 0 {
                newlyMatched[pattern.signal, default: 0] += matches
            }
            guard let threshold = pattern.lowContextPercentageThreshold,
                  !pattern.lowContextPercentagePhrases.isEmpty else {
                continue
            }
            let percentageMatches = Self.lowContextPercentageMatchCount(
                in: percentageCarry + normalized,
                threshold: threshold,
                phrases: pattern.lowContextPercentagePhrases,
                carryLength: percentageCarry.utf16.count,
                maximumMatches: Self.maximumPercentageMatchesPerPattern
            )
            if percentageMatches > 0 {
                newlyMatched[pattern.signal, default: 0] += percentageMatches
            }
        }
        let carryLength = max(definition.maximumMarkerLength - 1, 0)
        markerCarry = carryLength == 0 ? "" : String(combined.suffix(carryLength))
        let percentageCombined = percentageCarry + normalized
        percentageCarry = String(percentageCombined.suffix(64))

        var events: [AgentContextPressureEvent] = []
        for pattern in definition.patterns {
            let newMatches = newlyMatched[pattern.signal, default: 0]
            guard newMatches > 0 else { continue }
            let matchCount = occurrences[pattern.signal, default: 0] + newMatches
            occurrences[pattern.signal] = matchCount

            if matchCount >= pattern.eventThreshold {
                let newlyDetected = !detectedSignals.contains(pattern.signal)
                if newlyDetected {
                    detectedSignals.append(pattern.signal)
                    events.append(
                        AgentContextPressureEvent(
                            provider: provider,
                            signal: pattern.signal,
                            occurrence: matchCount
                        )
                    )
                }
            }
        }
        return events
    }

    /// Clears all pressure and parser state after a recovery action is acknowledged.
    public mutating func reset() {
        normalizer.reset()
        markerCarry.removeAll(keepingCapacity: true)
        percentageCarry.removeAll(keepingCapacity: true)
        occurrences.removeAll(keepingCapacity: true)
        detectedSignals.removeAll(keepingCapacity: true)
    }

    private static func newMatchRanges(
        of marker: String,
        in value: String,
        extendingPast carryBoundary: String.Index,
        maximumMatches: Int
    ) -> [Range<Int>] {
        guard !marker.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              ranges.count < maximumMatches,
              let range = value.range(of: marker, range: searchStart..<value.endIndex) {
            if range.upperBound > carryBoundary {
                let lowerBound = value.distance(from: value.startIndex, to: range.lowerBound)
                let upperBound = value.distance(from: value.startIndex, to: range.upperBound)
                ranges.append(lowerBound..<upperBound)
            }
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func distinctOccurrenceCount(in ranges: [Range<Int>]) -> Int {
        let sorted = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound > $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        guard var mergedRange = sorted.first else { return 0 }
        var count = 1
        for range in sorted.dropFirst() {
            if range.lowerBound < mergedRange.upperBound {
                mergedRange = mergedRange.lowerBound..<max(mergedRange.upperBound, range.upperBound)
            } else {
                count += 1
                mergedRange = range
            }
        }
        return count
    }

    private static func lowContextPercentageMatchCount(
        in value: String,
        threshold: Int,
        phrases: [String],
        carryLength: Int,
        maximumMatches: Int
    ) -> Int {
        guard !value.isEmpty, !phrases.isEmpty, maximumMatches > 0 else { return 0 }
        var matchedPercentageLocations = Set<Int>()
        for phrase in phrases {
            guard matchedPercentageLocations.count < maximumMatches else { break }
            var searchStart = value.startIndex
            while searchStart < value.endIndex,
                  matchedPercentageLocations.count < maximumMatches,
                  let phraseRange = value.range(of: phrase, range: searchStart..<value.endIndex) {
                let phraseEndOffset = phraseRange.upperBound.utf16Offset(in: value)
                searchStart = phraseRange.upperBound

                // Providers use both `8% context left` and `context left: 8%`.
                // Keep the separator for the latter deliberately narrow so
                // ordinary prose such as "context left in the explanation
                // 5%" is not pressure. A footer can straddle two PTY chunks
                // immediately after its label, so the trailing percentage is
                // considered new evidence even when the phrase itself is in
                // the carry buffer.
                let leadingNumber = percentageBefore(
                    in: value,
                    phraseStart: phraseRange.lowerBound
                )
                let trailingNumber = percentageAfter(
                    in: value,
                    phraseEnd: phraseRange.upperBound
                )
                let leadingMatch = phraseEndOffset > carryLength
                    && leadingNumber.map { $0.number <= threshold } == true
                let trailingMatch = trailingNumber.map { match in
                    match.endOffset > carryLength && match.number <= threshold
                } == true
                if leadingMatch, let leadingNumber {
                    matchedPercentageLocations.insert(leadingNumber.endOffset)
                    if matchedPercentageLocations.count >= maximumMatches {
                        return maximumMatches
                    }
                }
                if trailingMatch, let trailingNumber {
                    matchedPercentageLocations.insert(trailingNumber.endOffset)
                    if matchedPercentageLocations.count >= maximumMatches {
                        return maximumMatches
                    }
                }
            }
        }
        // Specific and broad phrases can overlap around the same percentage,
        // such as "context left until auto-compact" and "until auto-compact".
        // The percentage token identifies the provider event and prevents the
        // aliases from inflating its occurrence count.
        return matchedPercentageLocations.count
    }

    /// Parses a one-to-three-digit percentage immediately before a phrase,
    /// allowing only whitespace between the percent sign and the phrase.
    private static func percentageBefore(
        in value: String,
        phraseStart: String.Index
    ) -> (number: Int, endOffset: Int)? {
        var cursor = phraseStart
        var separatorCount = 0
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous].isWhitespace else { break }
            separatorCount += 1
            guard separatorCount <= 16 else { return nil }
            cursor = previous
        }
        guard cursor > value.startIndex else { return nil }
        let percentIndex = value.index(before: cursor)
        guard value[percentIndex] == "%" else { return nil }

        let digitEnd = percentIndex
        var digitStart = digitEnd
        var digitCount = 0
        while digitStart > value.startIndex, digitCount < 3 {
            let previous = value.index(before: digitStart)
            guard value[previous].isNumber else { break }
            digitStart = previous
            digitCount += 1
        }
        // Do not silently truncate a longer token to its last three digits.
        // `1005% context left` is not a valid bounded percentage and must not
        // become a false 5% pressure signal.
        if digitStart > value.startIndex,
           value[value.index(before: digitStart)].isNumber {
            return nil
        }
        guard digitCount > 0,
              let number = Int(value[digitStart..<digitEnd]) else {
            return nil
        }
        return (number, cursor.utf16Offset(in: value))
    }

    /// Parses a one-to-three-digit percentage after a phrase, allowing a
    /// bounded run of whitespace, `:`, or `-` separators.
    private static func percentageAfter(
        in value: String,
        phraseEnd: String.Index
    ) -> (number: Int, endOffset: Int)? {
        var cursor = phraseEnd
        var separatorCount = 0
        while cursor < value.endIndex {
            let character = value[cursor]
            guard character.isWhitespace || character == ":" || character == "-" else { break }
            separatorCount += 1
            guard separatorCount <= 16 else { return nil }
            cursor = value.index(after: cursor)
        }

        let digitStart = cursor
        var digitCount = 0
        while cursor < value.endIndex, digitCount < 3, value[cursor].isNumber {
            digitCount += 1
            cursor = value.index(after: cursor)
        }
        // Reject, rather than truncate, a token such as `1005%`. This keeps
        // the bounded percentage contract symmetric with `percentageBefore`.
        if cursor < value.endIndex, value[cursor].isNumber {
            return nil
        }
        guard digitCount > 0,
              cursor < value.endIndex,
              value[cursor] == "%",
              let number = Int(value[digitStart..<cursor]) else {
            return nil
        }
        return (number, cursor.utf16Offset(in: value))
    }
}
