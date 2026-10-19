import Foundation

/// Scans output once for a bounded set of broker control markers.
struct SudoExecutionMarkerMatcher: Sendable {
    typealias Marker = (bytes: [UInt8], kind: SudoExecutionMarkerKind)
    typealias Match = (offset: Int, markerIndex: Int)

    private let markers: [Marker]
    private let transitions: [[UInt8: Int]]
    private let failures: [Int]
    private let outputs: [[Int]]
    private let extendablePrefixLengths: [Int]
    private let maximumMarkerLength: Int

    init(markers: [Marker]) {
        self.markers = markers
        maximumMarkerLength = markers.map(\.bytes.count).max() ?? 0
        var builtTransitions: [[UInt8: Int]] = [[:]]
        var builtFailures = [0]
        var builtOutputs: [[Int]] = [[]]
        var builtDepths = [0]

        for (index, marker) in markers.enumerated() {
            var state = 0
            for byte in marker.bytes {
                if let next = builtTransitions[state][byte] {
                    state = next
                } else {
                    let next = builtTransitions.count
                    let depth = builtDepths[state] + 1
                    builtTransitions.append([:])
                    builtFailures.append(0)
                    builtOutputs.append([])
                    builtDepths.append(depth)
                    builtTransitions[state][byte] = next
                    state = next
                }
            }
            builtOutputs[state].append(index)
        }

        var queue = Array(builtTransitions[0].values)
        var queueIndex = 0
        while queueIndex < queue.count {
            let state = queue[queueIndex]
            queueIndex += 1
            let edges = builtTransitions[state]
            for (byte, next) in edges {
                var failure = builtFailures[state]
                while failure != 0, builtTransitions[failure][byte] == nil {
                    failure = builtFailures[failure]
                }
                if let fallback = builtTransitions[failure][byte], fallback != next {
                    builtFailures[next] = fallback
                }
                let inheritedOutputs = builtOutputs[builtFailures[next]]
                builtOutputs[next].append(contentsOf: inheritedOutputs)
                queue.append(next)
            }
        }

        transitions = builtTransitions
        failures = builtFailures
        outputs = builtOutputs
        extendablePrefixLengths = builtTransitions.indices.map { state in
            var longest = builtTransitions[state].isEmpty ? 0 : builtDepths[state]
            var failure = builtFailures[state]
            while failure != 0 {
                if !builtTransitions[failure].isEmpty {
                    longest = max(longest, builtDepths[failure])
                }
                failure = builtFailures[failure]
            }
            return longest
        }
    }

    /// Scans bytes once and returns the earliest marker plus the suffix that may begin one.
    func scan(
        _ bytes: ArraySlice<UInt8>,
        isFinal: Bool
    ) -> (match: Match?, retainedSuffixLength: Int) {
        var state = 0
        var earliestMatch: Match?
        for (offset, byte) in bytes.enumerated() {
            while state != 0, transitions[state][byte] == nil {
                state = failures[state]
            }
            state = transitions[state][byte] ?? 0
            for markerIndex in outputs[state] {
                let candidate = Match(
                    offset: offset + 1 - markers[markerIndex].bytes.count,
                    markerIndex: markerIndex
                )
                if let current = earliestMatch {
                    if candidate.offset < current.offset
                        || (candidate.offset == current.offset
                            && candidate.markerIndex < current.markerIndex) {
                        earliestMatch = candidate
                    }
                } else {
                    earliestMatch = candidate
                }
            }

            // A later marker cannot start before this point once the longest
            // marker-sized look-ahead has elapsed. Keep the first-start
            // semantics of the old range scanner without rescanning the whole
            // buffer for every marker.
            if let earliestMatch,
               maximumMarkerLength > 0,
               offset >= earliestMatch.offset + maximumMarkerLength - 1 {
                return (match: earliestMatch, retainedSuffixLength: 0)
            }
        }
        if let earliestMatch {
            if isFinal {
                return (match: earliestMatch, retainedSuffixLength: 0)
            }
            let unresolvedPrefixLength = extendablePrefixLengths[state]
            let unresolvedStart = bytes.count - unresolvedPrefixLength
            guard unresolvedPrefixLength > 0,
                  unresolvedStart <= earliestMatch.offset else {
                return (match: earliestMatch, retainedSuffixLength: 0)
            }
            return (
                match: nil,
                retainedSuffixLength: unresolvedPrefixLength
            )
        }
        return (
            match: nil,
            retainedSuffixLength: extendablePrefixLengths[state]
        )
    }
}
