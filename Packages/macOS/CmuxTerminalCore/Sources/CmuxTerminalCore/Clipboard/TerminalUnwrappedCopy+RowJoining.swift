extension TerminalUnwrappedCopy {
    /// Requires split-token evidence before removing the separator between rows.
    ///
    /// A word-wrapping TUI moves a whole URL to the next row unless it is
    /// longer than the row, so only punctuation at the cut shows a split.
    /// A row ending a sentence stays apart from a capitalized row only when
    /// that row's first word would still have fit in the grid.
    func rowJoinSeparator(
        after previous: String,
        before content: Substring,
        fillsWidth: Bool,
        nextWordFitsGrid: Bool
    ) -> String? {
        if nextWordFitsGrid, let last = previous.last, ".!?".contains(last),
           content.first?.isUppercase == true { return nil }
        let trimmed = previous.drop(while: \.isWhitespace)
        let tokens = trimmed.dropFirst(listPrefixLength(trimmed)).split(whereSeparator: \.isWhitespace)
        let nextToken = content.prefix(while: { !$0.isWhitespace })
        let last = tokens.last ?? ""
        let urlOrPath = last.contains("://") || last.hasPrefix("www.") || last.contains("/")
        let splitToken = fillsWidth && urlOrPath && (last.last.map { "/-_.?=&#%~+".contains($0) } == true
            || nextToken.contains(where: { "/?=&#%._-".contains($0) }))
        if tokens.count == 1 && !splitToken { return nil }
        return splitToken ? "" : " "
    }

    /// Headings, table rows and prompt rows never take the next row.
    func endsBlock(_ previous: String) -> Bool {
        let content = previous.drop(while: \.isWhitespace)
        return content.first == "#" || content.first == "|" || content.hasPrefix("$ ")
    }

    func listPrefixLength(_ content: Substring) -> Int {
        if let first = content.first, "-*+•".contains(first), content.dropFirst().first == " " {
            return content.prefix(2).count + content.dropFirst(2).prefix(while: { $0 == " " }).count
        }
        let digits = content.prefix(while: \.isNumber)
        let rest = content.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return digits.count + 2 + rest.dropFirst(2).prefix(while: { $0 == " " }).count
        }
        return 0
    }

}
