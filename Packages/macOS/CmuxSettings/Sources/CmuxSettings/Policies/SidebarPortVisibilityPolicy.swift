/// Filters raw listening-port observations for publication to sidebar consumers.
public struct SidebarPortVisibilityPolicy: Sendable, Equatable {
    /// The IANA dynamic/private range used for OS-assigned ephemeral ports.
    public static let operatingSystemEphemeralRange =
        SidebarIgnoredPortRule.operatingSystemEphemeralRange

    /// The ignored rules used when the user has not supplied an override.
    public static let defaultIgnoredRules: [SidebarIgnoredPortRule] = [
        .operatingSystemEphemeralRangeRule,
    ]

    /// Sorted, non-overlapping ranges used for logarithmic membership checks.
    private let ignoredRanges: [ClosedRange<Int>]

    /// Creates a sidebar port policy from the user's complete ignored-rules override.
    ///
    /// - Parameter ignoredRules: Exact ports and inclusive ranges to omit.
    public init(
        ignoredRules: [SidebarIgnoredPortRule] = SidebarPortVisibilityPolicy.defaultIgnoredRules
    ) {
        let sortedRanges = ignoredRules
            .map(\.inclusiveRange)
            .sorted { lhs, rhs in
                if lhs.lowerBound == rhs.lowerBound {
                    return lhs.upperBound < rhs.upperBound
                }
                return lhs.lowerBound < rhs.lowerBound
            }

        var coalescedRanges: [ClosedRange<Int>] = []
        coalescedRanges.reserveCapacity(sortedRanges.count)
        for range in sortedRanges {
            guard let previous = coalescedRanges.last,
                  range.lowerBound <= previous.upperBound + 1 else {
                coalescedRanges.append(range)
                continue
            }

            coalescedRanges[coalescedRanges.count - 1] = previous.lowerBound...max(
                previous.upperBound,
                range.upperBound
            )
        }
        ignoredRanges = coalescedRanges
    }

    /// Removes ignored ports while preserving the input order and duplicates.
    ///
    /// - Parameter ports: Raw listening ports collected for a workspace.
    /// - Returns: Ports eligible for sidebar publication.
    public func visiblePorts(from ports: [Int]) -> [Int] {
        ports.filter { !contains($0) }
    }

    /// Returns whether the normalized range index contains `port`.
    private func contains(_ port: Int) -> Bool {
        var lowerIndex = ignoredRanges.startIndex
        var upperIndex = ignoredRanges.endIndex

        while lowerIndex < upperIndex {
            let middleIndex = lowerIndex + (upperIndex - lowerIndex) / 2
            let range = ignoredRanges[middleIndex]
            if port < range.lowerBound {
                upperIndex = middleIndex
            } else if port > range.upperBound {
                lowerIndex = middleIndex + 1
            } else {
                return true
            }
        }

        return false
    }
}
