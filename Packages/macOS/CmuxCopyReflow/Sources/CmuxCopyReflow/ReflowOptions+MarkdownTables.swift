extension ReflowOptions {
    /// Promotes loose pipe rows around a Markdown separator without treating
    /// every shell pipeline as a table.
    func promoteMarkdownTableRows(_ lines: [Substring], lineKinds: inout [LineKind]) {
        guard lines.count == lineKinds.count else { return }
        var index = lines.startIndex
        while index < lines.endIndex {
            guard isPromotableTableKind(lineKinds[index]),
                  lineKindIsMarkdownTableSeparatorRow(lines[index]) else {
                index += 1
                continue
            }

            lineKinds[index] = .tableRow
            let headerIndex = index - 1
            if headerIndex >= lines.startIndex,
               isPromotableTableKind(lineKinds[headerIndex]),
               lineKindIsMarkdownTableCandidateRow(lines[headerIndex]) {
                lineKinds[headerIndex] = .tableRow
            }

            var bodyIndex = index + 1
            while bodyIndex < lines.endIndex,
                  isPromotableTableKind(lineKinds[bodyIndex]),
                  lineKindIsMarkdownTableCandidateRow(lines[bodyIndex]) {
                lineKinds[bodyIndex] = .tableRow
                bodyIndex += 1
            }
            index = bodyIndex
        }
    }

    func isPromotableTableKind(_ kind: LineKind) -> Bool {
        switch kind {
        case .prose, .tableRow:
            return true
        case .blank, .fenceDelimiter, .insideFence, .heading, .blockquote, .listItem, .urlLine:
            return false
        }
    }
}
