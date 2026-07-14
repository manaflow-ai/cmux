/// Splices fetched context into immutable rows while preserving gap identity and numbering.
struct ContextRowSplicer: Sendable {
    /// Creates a context row splicer.
    init() {}

    /// Replaces or moves one gap row around returned context.
    /// - Parameters:
    ///   - rows: Current file rows.
    ///   - gapID: Identity of the gap being expanded.
    ///   - plan: Request plan used for the response.
    ///   - texts: Returned new-side source lines.
    /// - Returns: Updated rows; unchanged if the gap no longer exists.
    func splice(
        rows: [DiffRowSnapshot],
        gapID: String,
        plan: ContextExpansionPlan,
        texts: [String]
    ) -> [DiffRowSnapshot] {
        guard let index = rows.firstIndex(where: { $0.expansionGap?.id == gapID }),
              let gap = rows[index].expansionGap else { return rows }
        let contextRows = texts.enumerated().map { offset, text in
            let newLine = plan.requestedRange.lowerBound + offset
            return DiffRowSnapshot(
                id: "context:\(gapID):\(newLine)",
                kind: .context,
                oldLineNumber: newLine + gap.oldLineDelta,
                newLineNumber: newLine,
                marker: " ",
                text: text
            )
        }
        let remaining = plan.remainingGap(from: gap, returnedCount: texts.count).map { next in
            DiffRowSnapshot(
                id: rows[index].id,
                kind: .expansionGap,
                text: "",
                expansionGap: next
            )
        }
        var replacement: [DiffRowSnapshot] = []
        switch plan.direction {
        case .down, .all:
            replacement.append(contentsOf: contextRows)
            if let remaining { replacement.append(remaining) }
        case .up:
            if let remaining { replacement.append(remaining) }
            replacement.append(contentsOf: contextRows)
        }
        var result = rows
        result.replaceSubrange(index...index, with: replacement)
        return result
    }
}
