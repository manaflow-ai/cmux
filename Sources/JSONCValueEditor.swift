import Foundation

enum JSONCValueEditor {
    enum EditError: Error, CustomStringConvertible {
        case invalidPath(String)
        case missingPath(String)
        case expectedRootObject
        case expectedObject(String)
        case malformedJSONC(String)

        var description: String {
            switch self {
            case .invalidPath(let path):
                return "invalid JSON path '\(path)'"
            case .missingPath(let path):
                return "missing JSON path '\(path)'"
            case .expectedRootObject:
                return "expected root JSON object"
            case .expectedObject(let path):
                return "expected object at JSON path '\(path)'"
            case .malformedJSONC(let message):
                return "malformed JSONC: \(message)"
            }
        }
    }

    static func literal(for value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        guard let wrapped = String(data: data, encoding: .utf8) else {
            throw EditError.malformedJSONC("failed to encode replacement value")
        }
        guard wrapped.first == "[", wrapped.last == "]" else {
            throw EditError.malformedJSONC("failed to encode replacement value")
        }
        let start = wrapped.index(after: wrapped.startIndex)
        let end = wrapped.index(before: wrapped.endIndex)
        return wrapped[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func settingValues(
        _ replacements: [(jsonPath: String, literal: String)],
        in text: String
    ) throws -> String {
        var output = text
        for replacement in replacements {
            let finder = JSONCValueRangeFinder(text: output)
            if let range = try finder.valueRange(for: replacement.jsonPath) {
                output.replaceSubrange(range, with: replacement.literal)
            } else {
                output = try finder.insertingValue(replacement.literal, for: replacement.jsonPath)
            }
        }
        return output
    }
}

private struct JSONCValueRangeFinder {
    let text: String

    func valueRange(for jsonPath: String) throws -> Range<String.Index>? {
        let components = try pathComponents(for: jsonPath)

        let rootStart = skipTrivia(from: text.startIndex)
        guard rootStart < text.endIndex, text[rootStart] == "{" else {
            throw JSONCValueEditor.EditError.expectedRootObject
        }

        var objectStart = rootStart
        var traversed: [String] = []
        for (index, component) in components.enumerated() {
            guard let memberRange = try memberValueRange(inObjectAt: objectStart, key: component) else {
                return nil
            }
            traversed.append(component)
            if index == components.count - 1 {
                return memberRange
            }

            let nestedStart = skipTrivia(from: memberRange.lowerBound)
            guard nestedStart < text.endIndex, text[nestedStart] == "{" else {
                throw JSONCValueEditor.EditError.expectedObject(traversed.joined(separator: "."))
            }
            objectStart = nestedStart
        }
        return nil
    }

    func insertingValue(_ literal: String, for jsonPath: String) throws -> String {
        let components = try pathComponents(for: jsonPath)

        let rootStart = skipTrivia(from: text.startIndex)
        guard rootStart < text.endIndex, text[rootStart] == "{" else {
            throw JSONCValueEditor.EditError.expectedRootObject
        }

        return try insertingValue(
            literal,
            for: components,
            inObjectAt: rootStart,
            traversed: []
        )
    }

    private func pathComponents(for jsonPath: String) throws -> [String] {
        let components = jsonPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
            throw JSONCValueEditor.EditError.invalidPath(jsonPath)
        }
        return components
    }

    private func insertingValue(
        _ literal: String,
        for components: [String],
        inObjectAt objectStart: String.Index,
        traversed: [String]
    ) throws -> String {
        let key = components[0]
        if components.count == 1 {
            return try insertingMember(key: key, valueLiteral: literal, inObjectAt: objectStart)
        }

        if let memberRange = try memberValueRange(inObjectAt: objectStart, key: key) {
            let nestedStart = skipTrivia(from: memberRange.lowerBound)
            guard nestedStart < text.endIndex, text[nestedStart] == "{" else {
                throw JSONCValueEditor.EditError.expectedObject((traversed + [key]).joined(separator: "."))
            }
            return try insertingValue(
                literal,
                for: Array(components.dropFirst()),
                inObjectAt: nestedStart,
                traversed: traversed + [key]
            )
        }

        let nestedLiteral = try objectLiteral(for: Array(components.dropFirst()), leafLiteral: literal)
        return try insertingMember(key: key, valueLiteral: nestedLiteral, inObjectAt: objectStart)
    }

    private func memberValueRange(inObjectAt objectStart: String.Index, key: String) throws -> Range<String.Index>? {
        guard objectStart < text.endIndex, text[objectStart] == "{" else {
            throw JSONCValueEditor.EditError.expectedRootObject
        }

        var cursor = text.index(after: objectStart)
        while cursor < text.endIndex {
            cursor = skipTrivia(from: cursor)
            guard cursor < text.endIndex else { break }
            if text[cursor] == "}" {
                return nil
            }

            let parsedKey = try scanString(from: cursor)
            cursor = skipTrivia(from: parsedKey.end)
            guard cursor < text.endIndex, text[cursor] == ":" else {
                throw JSONCValueEditor.EditError.malformedJSONC("expected ':' after object key")
            }

            let valueStart = skipTrivia(from: text.index(after: cursor))
            let valueEnd = try scanValueEnd(from: valueStart)
            if parsedKey.value == key {
                return valueStart..<valueEnd
            }

            cursor = skipTrivia(from: valueEnd)
            if cursor < text.endIndex, text[cursor] == "," {
                cursor = text.index(after: cursor)
                continue
            }
            if cursor < text.endIndex, text[cursor] == "}" {
                return nil
            }
        }

        throw JSONCValueEditor.EditError.malformedJSONC("unterminated object")
    }

    private func insertingMember(
        key: String,
        valueLiteral: String,
        inObjectAt objectStart: String.Index
    ) throws -> String {
        let objectEnd = try scanBalanced(from: objectStart, open: "{", close: "}")
        let closingBrace = text.index(before: objectEnd)
        let closeIndent = indentation(containing: closingBrace)
        let childIndent = closeIndent + "  "
        let quotedKey = try JSONCValueEditor.literal(for: key)

        if let tail = try lastObjectMemberTail(objectStart: objectStart, closingBrace: closingBrace) {
            let closeLineStart = lineStart(containing: closingBrace)
            let insertionIndex = closeLineStart > tail.valueEnd ? closeLineStart : trailingWhitespaceStart(before: closingBrace)
            let comma = tail.hasTrailingComma ? "" : ","
            let inserted = "\(childIndent)\(quotedKey): \(valueLiteral)\n"
            return String(text[..<tail.valueEnd])
                + comma
                + String(text[tail.valueEnd..<insertionIndex])
                + inserted
                + String(text[insertionIndex...])
        }

        let insertionIndex = trailingWhitespaceStart(before: closingBrace)
        let hasClosingWhitespace = insertionIndex < closingBrace
        let trailing = hasClosingWhitespace ? "" : "\n\(closeIndent)"
        let inserted = "\n\(childIndent)\(quotedKey): \(valueLiteral)\(trailing)"

        var output = text
        output.insert(contentsOf: inserted, at: insertionIndex)
        return output
    }

    private func objectLiteral(for components: [String], leafLiteral: String) throws -> String {
        guard let key = components.first else { return leafLiteral }
        let value = try objectLiteral(for: Array(components.dropFirst()), leafLiteral: leafLiteral)
        let quotedKey = try JSONCValueEditor.literal(for: key)
        return "{\(quotedKey): \(value)}"
    }

    private func objectHasMembers(
        objectStart: String.Index,
        closingBrace: String.Index
    ) throws -> Bool {
        var cursor = text.index(after: objectStart)
        cursor = skipTrivia(from: cursor)
        return cursor < closingBrace
    }

    private struct ObjectMemberTail {
        var valueEnd: String.Index
        var hasTrailingComma: Bool
    }

    private func lastObjectMemberTail(
        objectStart: String.Index,
        closingBrace: String.Index
    ) throws -> ObjectMemberTail? {
        guard try objectHasMembers(objectStart: objectStart, closingBrace: closingBrace) else {
            return nil
        }

        var cursor = text.index(after: objectStart)
        var tail: ObjectMemberTail?
        while cursor < closingBrace {
            cursor = skipTrivia(from: cursor)
            guard cursor < closingBrace, text[cursor] != "}" else { return tail }

            let key = try scanString(from: cursor)
            cursor = skipTrivia(from: key.end)
            guard cursor < text.endIndex, text[cursor] == ":" else {
                throw JSONCValueEditor.EditError.malformedJSONC("expected ':' after object key")
            }

            let valueStart = skipTrivia(from: text.index(after: cursor))
            let valueEnd = try scanValueEnd(from: valueStart)
            cursor = skipTrivia(from: valueEnd)
            let hasComma = cursor < closingBrace && text[cursor] == ","
            tail = ObjectMemberTail(valueEnd: valueEnd, hasTrailingComma: hasComma)
            guard hasComma else {
                guard cursor >= closingBrace || text[cursor] == "}" else {
                    throw JSONCValueEditor.EditError.malformedJSONC("expected ',' between object members")
                }
                return tail
            }
            cursor = text.index(after: cursor)
        }
        return tail
    }

    private func trailingWhitespaceStart(before index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isWhitespace else { break }
            cursor = previous
        }
        return cursor
    }

    private func lineStart(containing index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous].isNewline { break }
            cursor = previous
        }
        return cursor
    }

    private func indentation(containing index: String.Index) -> String {
        var lineStart = index
        while lineStart > text.startIndex {
            let previous = text.index(before: lineStart)
            if text[previous].isNewline { break }
            lineStart = previous
        }

        var cursor = lineStart
        var indentation = ""
        while cursor < index {
            let character = text[cursor]
            guard character == " " || character == "\t" else { break }
            indentation.append(character)
            cursor = text.index(after: cursor)
        }
        return indentation
    }

    private func scanValueEnd(from start: String.Index) throws -> String.Index {
        guard start < text.endIndex else {
            throw JSONCValueEditor.EditError.malformedJSONC("expected value")
        }

        switch text[start] {
        case "{":
            return try scanBalanced(from: start, open: "{", close: "}")
        case "[":
            return try scanBalanced(from: start, open: "[", close: "]")
        case "\"":
            return try scanString(from: start).end
        default:
            return scanPrimitiveEnd(from: start)
        }
    }

    private func scanBalanced(
        from start: String.Index,
        open: Character,
        close: Character
    ) throws -> String.Index {
        guard start < text.endIndex, text[start] == open else {
            throw JSONCValueEditor.EditError.malformedJSONC("expected container")
        }
        var cursor = start
        var stack: [Character] = []
        var inString = false
        var isEscaped = false

        while cursor < text.endIndex {
            let character = text[cursor]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }

            if character == "\"" {
                inString = true
                cursor = text.index(after: cursor)
                continue
            }
            if character == "/", let skipped = skipComment(fromSlashAt: cursor) {
                cursor = skipped
                continue
            }
            if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                guard let last = stack.last,
                      character == expectedClose(for: last) else {
                    throw JSONCValueEditor.EditError.malformedJSONC("mismatched container delimiter")
                }
                stack.removeLast()
                if stack.isEmpty {
                    return text.index(after: cursor)
                }
            }
            cursor = text.index(after: cursor)
        }

        throw JSONCValueEditor.EditError.malformedJSONC("unterminated container")
    }

    private func expectedClose(for open: Character) -> Character {
        open == "{" ? "}" : "]"
    }

    private func scanPrimitiveEnd(from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "," || character == "}" || character == "]" ||
                character.isWhitespace ||
                (character == "/" && skipComment(fromSlashAt: cursor) != nil) {
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private func scanString(from start: String.Index) throws -> (value: String, end: String.Index) {
        guard start < text.endIndex, text[start] == "\"" else {
            throw JSONCValueEditor.EditError.malformedJSONC("expected string")
        }

        var cursor = text.index(after: start)
        var isEscaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let end = text.index(after: cursor)
                let literal = String(text[start..<end])
                let data = Data("[\(literal)]".utf8)
                do {
                    if let decoded = try JSONSerialization.jsonObject(with: data, options: []) as? [String],
                       let value = decoded.first {
                        return (value, end)
                    }
                } catch {
                    throw JSONCValueEditor.EditError.malformedJSONC("invalid string literal: \(error)")
                }
                throw JSONCValueEditor.EditError.malformedJSONC("invalid string literal")
            }
            cursor = text.index(after: cursor)
        }

        throw JSONCValueEditor.EditError.malformedJSONC("unterminated string")
    }

    private func skipTrivia(from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor].isWhitespace || text[cursor] == "\u{feff}" {
                cursor = text.index(after: cursor)
                continue
            }
            if text[cursor] == "/", let skipped = skipComment(fromSlashAt: cursor) {
                cursor = skipped
                continue
            }
            break
        }
        return cursor
    }

    private func skipComment(fromSlashAt start: String.Index) -> String.Index? {
        let marker = text.index(after: start)
        guard marker < text.endIndex else { return nil }

        if text[marker] == "/" {
            var cursor = text.index(after: marker)
            while cursor < text.endIndex, text[cursor].isNewline == false {
                cursor = text.index(after: cursor)
            }
            return cursor
        }

        if text[marker] == "*" {
            var cursor = text.index(after: marker)
            while cursor < text.endIndex {
                let next = text.index(after: cursor)
                if text[cursor] == "*", next < text.endIndex, text[next] == "/" {
                    return text.index(after: next)
                }
                cursor = next
            }
            return text.endIndex
        }

        return nil
    }
}
