/// Direction in which an omitted context interval is expanded.
enum ContextExpansionDirection: Sendable, Equatable {
    /// Fetches from the start of the interval toward the following hunk or EOF.
    case down
    /// Fetches backward from the end of a bounded interval.
    case up
    /// Fetches the entire bounded interval.
    case all
}

/// A bounded context request and the updated gap produced by its response.
struct ContextExpansionPlan: Sendable, Equatable {
    /// Requested inclusive new-side line interval.
    let requestedRange: ClosedRange<Int>
    /// Direction controlling insertion around the existing gap row.
    let direction: ContextExpansionDirection

    /// Creates a context expansion request.
    /// - Parameters:
    ///   - requestedRange: Inclusive new-side request interval.
    ///   - direction: Expansion direction.
    init(requestedRange: ClosedRange<Int>, direction: ContextExpansionDirection) {
        self.requestedRange = requestedRange
        self.direction = direction
    }

    /// Plans a context request of at most the supplied chunk size.
    /// - Parameters:
    ///   - gap: Omitted interval being expanded.
    ///   - direction: Requested direction.
    ///   - chunkSize: Maximum lines for directional expansion.
    /// - Returns: A valid plan, or `nil` when the direction cannot apply.
    init?(gap: DiffExpansionGap, direction: ContextExpansionDirection, chunkSize: Int = 20) {
        guard chunkSize > 0 else { return nil }
        self.direction = direction
        switch direction {
        case .down:
            let end = min(gap.newEnd ?? (gap.newStart + chunkSize - 1), gap.newStart + chunkSize - 1)
            requestedRange = gap.newStart...end
        case .up:
            guard let end = gap.newEnd else { return nil }
            requestedRange = max(gap.newStart, end - chunkSize + 1)...end
        case .all:
            guard let end = gap.newEnd else { return nil }
            requestedRange = gap.newStart...end
        }
    }

    /// Derives the remaining gap after receiving a context response.
    /// - Parameters:
    ///   - gap: Original omitted interval.
    ///   - returnedCount: Number of lines returned by the service.
    /// - Returns: The remaining interval, or `nil` when exhausted.
    func remainingGap(from gap: DiffExpansionGap, returnedCount: Int) -> DiffExpansionGap? {
        let received = max(0, min(returnedCount, requestedRange.count))
        switch direction {
        case .all:
            return nil
        case .down:
            guard received == requestedRange.count else { return nil }
            let nextStart = requestedRange.upperBound + 1
            if let end = gap.newEnd, nextStart > end { return nil }
            return DiffExpansionGap(
                id: gap.id,
                newStart: nextStart,
                newEnd: gap.newEnd,
                oldLineDelta: gap.oldLineDelta
            )
        case .up:
            guard received == requestedRange.count else { return nil }
            let nextEnd = requestedRange.lowerBound - 1
            guard nextEnd >= gap.newStart else { return nil }
            return DiffExpansionGap(
                id: gap.id,
                newStart: gap.newStart,
                newEnd: nextEnd,
                oldLineDelta: gap.oldLineDelta
            )
        }
    }
}
