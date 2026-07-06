import Foundation

// MARK: - Property removal (comment-preserving)

extension JSONCObjectEditor {
    /// Removes `parentKey.childKey` from a JSONC object source, preserving all
    /// comments and formatting outside the removed entry. Returns nil when the
    /// property does not exist, the document shape is unexpected, or removal
    /// would require editing around a block comment (refused rather than
    /// risking user content).
    static func removeNestedObjectProperty(
        parentKey: String,
        childKey: String,
        in source: String
    ) -> String? {
        guard let root = rootObject(in: source),
              let parent = root.property(named: parentKey) else { return nil }
        let parentValueStart = skipWhitespaceAndComments(in: source, from: parent.valueStart)
        guard parentValueStart < source.endIndex,
              source[parentValueStart] == "{",
              let parentObject = parseObject(in: source, at: parentValueStart),
              let child = parentObject.property(named: childKey) else { return nil }

        // Eat the removed entry's leading indentation.
        var removeStart = startOfLine(containing: child.keyStart, in: source)
        var removeEnd = child.valueEnd

        // Trailing spaces, then an optional trailing comma.
        removeEnd = advancing(removeEnd, overSpacesIn: source)
        var hadTrailingComma = false
        if removeEnd < source.endIndex, source[removeEnd] == "," {
            hadTrailingComma = true
            removeEnd = source.index(after: removeEnd)
            removeEnd = advancing(removeEnd, overSpacesIn: source)
        }
        // A line comment on the entry's closing line belongs to the entry.
        if source[removeEnd...].hasPrefix("//") {
            while removeEnd < source.endIndex, !JSONCParser.isLineTerminator(source[removeEnd]) {
                removeEnd = source.index(after: removeEnd)
            }
        }
        // Consume one line terminator so no blank line is left behind.
        if removeEnd < source.endIndex, JSONCParser.isLineTerminator(source[removeEnd]) {
            if source[removeEnd...].hasPrefix("\r\n") {
                removeEnd = source.index(removeEnd, offsetBy: 2)
            } else {
                removeEnd = source.index(after: removeEnd)
            }
        }

        if !hadTrailingComma {
            // Last property: the separating comma sits before it, possibly
            // behind whitespace or a previous entry's line comment.
            guard let comma = precedingCommaIndex(before: removeStart, in: source) else {
                // No separator at all only happens for a sole property; then
                // there is nothing to splice. Anything else is a shape we
                // refuse to edit.
                if parentObject.properties.count == 1 {
                    return replacing(source, from: removeStart, to: removeEnd, with: "")
                }
                return nil
            }
            guard comma < removeStart else {
                return nil
            }
            // Both removals in one reconstruction: every index here belongs
            // to `source` (String.Index values must not cross string
            // instances).
            return String(source[source.startIndex..<comma])
                + String(source[source.index(after: comma)..<removeStart])
                + String(source[removeEnd...])
        }

        return replacing(source, from: removeStart, to: removeEnd, with: "")
    }

    private static func startOfLine(containing index: String.Index, in source: String) -> String.Index {
        var lineStart = index
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if JSONCParser.isLineTerminator(source[previous]) {
                break
            }
            lineStart = previous
        }
        return lineStart
    }

    private static func advancing(_ index: String.Index, overSpacesIn source: String) -> String.Index {
        var cursor = index
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    /// Finds the comma separating the previous property from the one starting
    /// at `limit`, scanning back over whitespace and line comments. Returns
    /// nil (refusal) when anything else — e.g. a block comment — is in the
    /// way, rather than risking a structurally wrong edit.
    private static func precedingCommaIndex(before limit: String.Index, in source: String) -> String.Index? {
        var cursor = limit
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            let character = source[previous]
            if character == " " || character == "\t" || JSONCParser.isLineTerminator(character) {
                cursor = previous
                continue
            }
            if character == "," {
                return previous
            }
            // The non-whitespace tail might be a line comment ("value", // note).
            // Lex the line forward (string-aware) to find a genuine comment start.
            let lineStart = startOfLine(containing: previous, in: source)
            guard let commentStart = lineCommentStart(inLineStartingAt: lineStart, in: source),
                  commentStart <= previous else {
                return nil
            }
            cursor = commentStart
        }
        return nil
    }

    /// Forward-lexes one line, honoring string literals and escapes, and
    /// returns where a `//` line comment starts, if any.
    private static func lineCommentStart(
        inLineStartingAt lineStart: String.Index,
        in source: String
    ) -> String.Index? {
        var cursor = lineStart
        var insideString = false
        while cursor < source.endIndex, !JSONCParser.isLineTerminator(source[cursor]) {
            let character = source[cursor]
            if insideString {
                if character == "\\" {
                    cursor = source.index(after: cursor)
                    if cursor >= source.endIndex { return nil }
                } else if character == "\"" {
                    insideString = false
                }
            } else if character == "\"" {
                insideString = true
            } else if character == "/", source[source.index(after: cursor)...].hasPrefix("/") {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}
