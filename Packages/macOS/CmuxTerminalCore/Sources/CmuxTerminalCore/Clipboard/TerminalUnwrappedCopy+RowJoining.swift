extension TerminalUnwrappedCopy {
    /// Requires split-token evidence before removing the separator between rows.
    ///
    /// A URL or path that fills the wrap width was cut mid-token when the
    /// selection confirms that width, or when punctuation at the cut shows it.
    func rowJoinSeparator(
        after previous: String,
        before content: Substring,
        fillsWidth: Bool,
        wrapWidthConfirmed: Bool
    ) -> String? {
        if let last = previous.last, ".!?".contains(last), content.first?.isUppercase == true { return nil }
        let trimmed = previous.drop(while: \.isWhitespace)
        let tokens = trimmed.dropFirst(listPrefixLength(trimmed)).split(whereSeparator: \.isWhitespace)
        let nextToken = content.prefix(while: { !$0.isWhitespace })
        let last = tokens.last ?? ""
        let urlOrPath = last.contains("://") || last.hasPrefix("www.") || last.contains("/")
        let splitToken = fillsWidth && urlOrPath && (wrapWidthConfirmed
            || last.last.map { "/-_.?=&#%~+".contains($0) } == true
            || nextToken.contains(where: { "/?=&#%.".contains($0) }))
        if tokens.count == 1 && !splitToken { return nil }
        return splitToken ? "" : " "
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
