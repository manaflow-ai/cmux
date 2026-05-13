import Foundation

enum CmuxSettingsJSONCEditor {
    static func updatingMember(
        in source: String,
        keyPath: [String],
        valueText: String
    ) throws -> String {
        guard !keyPath.isEmpty else {
            throw JSONCEditError.valueNotFound
        }
        let rootRange = try rootObjectRange(in: source)
        return try updatingMember(
            in: source,
            objectRange: rootRange,
            keyPath: ArraySlice(keyPath),
            valueText: valueText
        )
    }

    private static func updatingMember(
        in source: String,
        objectRange: Range<String.Index>,
        keyPath: ArraySlice<String>,
        valueText: String
    ) throws -> String {
        guard let key = keyPath.first else {
            throw JSONCEditError.valueNotFound
        }

        if keyPath.count == 1 {
            if let existingValueRange = try valueRange(forKey: key, inObjectRange: objectRange, source: source) {
                var updated = source
                updated.replaceSubrange(existingValueRange, with: valueText)
                try validateJSONC(updated)
                return updated
            }

            let updated = try insertingMember(
                key: key,
                valueText: valueText,
                intoObjectRange: objectRange,
                source: source
            )
            try validateJSONC(updated)
            return updated
        }

        let remainingKeyPath = keyPath.dropFirst()
        let memberIndent = memberIndent(in: source, objectRange: objectRange)
        let objectText = jsonObjectText(
            keyPath: remainingKeyPath,
            valueText: valueText,
            memberIndent: memberIndent,
            source: source
        )

        if let existingValueRange = try valueRange(forKey: key, inObjectRange: objectRange, source: source) {
            if let nestedObjectRange = try objectRangeForValue(forValueRange: existingValueRange, in: source) {
                return try updatingMember(
                    in: source,
                    objectRange: nestedObjectRange,
                    keyPath: remainingKeyPath,
                    valueText: valueText
                )
            }

            var updated = source
            updated.replaceSubrange(existingValueRange, with: objectText)
            try validateJSONC(updated)
            return updated
        }

        let updated = try insertingMember(
            key: key,
            valueText: objectText,
            intoObjectRange: objectRange,
            source: source
        )
        try validateJSONC(updated)
        return updated
    }

    private static func rootObjectRange(in source: String) throws -> Range<String.Index> {
        var index = source.startIndex
        try skipJSONCTrivia(in: source, index: &index, upTo: source.endIndex)
        guard index < source.endIndex, source[index] == "{" else {
            throw JSONCEditError.rootObjectNotFound
        }
        guard let closeIndex = try matchingDelimiter(
            from: index,
            open: "{",
            close: "}",
            in: source,
            upTo: source.endIndex
        ) else {
            throw JSONCEditError.unterminatedObject
        }
        return index..<source.index(after: closeIndex)
    }

    private static func objectRangeForValue(
        forValueRange valueRange: Range<String.Index>,
        in source: String
    ) throws -> Range<String.Index>? {
        guard valueRange.lowerBound < valueRange.upperBound,
              source[valueRange.lowerBound] == "{" else {
            return nil
        }
        guard let closeIndex = try matchingDelimiter(
            from: valueRange.lowerBound,
            open: "{",
            close: "}",
            in: source,
            upTo: source.endIndex
        ) else {
            throw JSONCEditError.unterminatedObject
        }
        return valueRange.lowerBound..<source.index(after: closeIndex)
    }

    private static func insertingMember(
        key: String,
        valueText: String,
        intoObjectRange objectRange: Range<String.Index>,
        source: String
    ) throws -> String {
        let hasMembers = try firstActiveMemberIndent(in: objectRange, source: source) != nil
        let memberIndent = memberIndent(in: source, objectRange: objectRange)
        let closingIndent = closingIndent(in: source, objectRange: objectRange)
        let suffix = hasMembers ? "," : "\n\(closingIndent)"
        let insertion = "\n\(memberIndent)\"\(key)\": \(valueText)\(suffix)"
        var updated = source
        updated.insert(contentsOf: insertion, at: source.index(after: objectRange.lowerBound))
        return updated
    }

    private static func memberIndent(
        in source: String,
        objectRange: Range<String.Index>
    ) -> String {
        do {
            if let existingIndent = try firstActiveMemberIndent(in: objectRange, source: source) {
                return existingIndent
            }
        } catch {
            return closingIndent(in: source, objectRange: objectRange) + indentUnit(in: source)
        }
        return closingIndent(in: source, objectRange: objectRange) + indentUnit(in: source)
    }

    private static func closingIndent(
        in source: String,
        objectRange: Range<String.Index>
    ) -> String {
        guard objectRange.upperBound > objectRange.lowerBound else { return "" }
        let closeIndex = source.index(before: objectRange.upperBound)
        return indentationBefore(closeIndex, in: source)
    }

    private static func indentationBefore(_ index: String.Index, in source: String) -> String {
        var lineStart = index
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if source[previous] == "\n" || source[previous] == "\r" {
                break
            }
            lineStart = previous
        }

        var cursor = lineStart
        var indentation = ""
        while cursor < index {
            let character = source[cursor]
            if character == " " || character == "\t" {
                indentation.append(character)
                cursor = source.index(after: cursor)
                continue
            }
            return ""
        }
        return indentation
    }

    private static func indentUnit(in source: String) -> String {
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? source.endIndex
            var cursor = lineStart
            var indentation = ""
            while cursor < lineEnd {
                let character = source[cursor]
                if character == " " || character == "\t" {
                    indentation.append(character)
                    cursor = source.index(after: cursor)
                    continue
                }
                if character == "\"", !indentation.isEmpty {
                    return indentation
                }
                break
            }
            lineStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
        }
        return "  "
    }

    private static func firstActiveMemberIndent(
        in objectRange: Range<String.Index>,
        source: String
    ) throws -> String? {
        guard source[objectRange.lowerBound] == "{" else { return nil }
        let closeIndex = source.index(before: objectRange.upperBound)
        var index = source.index(after: objectRange.lowerBound)
        while index < closeIndex {
            try skipJSONCTrivia(in: source, index: &index, upTo: closeIndex)
            guard index < closeIndex else { break }
            if source[index] == "," {
                index = source.index(after: index)
                continue
            }
            guard source[index] == "\"" else {
                index = source.index(after: index)
                continue
            }
            guard let string = try parseJSONString(in: source, from: index, upTo: closeIndex) else {
                return nil
            }
            var afterKey = string.range.upperBound
            try skipJSONCTrivia(in: source, index: &afterKey, upTo: closeIndex)
            if afterKey < closeIndex, source[afterKey] == ":" {
                return indentationBefore(index, in: source)
            }
            index = string.range.upperBound
        }
        return nil
    }

    private static func jsonObjectText(
        keyPath: ArraySlice<String>,
        valueText: String,
        memberIndent: String,
        source: String
    ) -> String {
        guard let key = keyPath.first else { return valueText }
        let childIndent = memberIndent + indentUnit(in: source)
        let childValueText = jsonObjectText(
            keyPath: keyPath.dropFirst(),
            valueText: valueText,
            memberIndent: childIndent,
            source: source
        )
        return "{\n\(childIndent)\"\(key)\": \(childValueText)\n\(memberIndent)}"
    }

    private static func valueRange(
        forKey key: String,
        inObjectRange objectRange: Range<String.Index>,
        source: String
    ) throws -> Range<String.Index>? {
        guard source[objectRange.lowerBound] == "{" else { return nil }
        let closeIndex = source.index(before: objectRange.upperBound)
        var index = source.index(after: objectRange.lowerBound)
        while index < closeIndex {
            try skipJSONCTrivia(in: source, index: &index, upTo: closeIndex)
            guard index < closeIndex else { break }
            if source[index] == "," {
                index = source.index(after: index)
                continue
            }
            guard source[index] == "\"" else {
                index = source.index(after: index)
                continue
            }

            guard let parsedKey = try parseJSONString(in: source, from: index, upTo: closeIndex) else {
                return nil
            }
            var valueStart = parsedKey.range.upperBound
            try skipJSONCTrivia(in: source, index: &valueStart, upTo: closeIndex)
            guard valueStart < closeIndex, source[valueStart] == ":" else {
                index = parsedKey.range.upperBound
                continue
            }
            valueStart = source.index(after: valueStart)
            try skipJSONCTrivia(in: source, index: &valueStart, upTo: closeIndex)
            let value = try scanValueRange(from: valueStart, upTo: closeIndex, in: source)
            if parsedKey.value == key {
                return value
            }
            index = value.upperBound
        }
        return nil
    }

    private static func scanValueRange(
        from valueStart: String.Index,
        upTo limit: String.Index,
        in source: String
    ) throws -> Range<String.Index> {
        guard valueStart < limit else { throw JSONCEditError.valueNotFound }
        switch source[valueStart] {
        case "{":
            guard let closeIndex = try matchingDelimiter(
                from: valueStart,
                open: "{",
                close: "}",
                in: source,
                upTo: limit
            ) else {
                throw JSONCEditError.unterminatedObject
            }
            return valueStart..<source.index(after: closeIndex)
        case "[":
            guard let closeIndex = try matchingDelimiter(
                from: valueStart,
                open: "[",
                close: "]",
                in: source,
                upTo: limit
            ) else {
                throw JSONCEditError.unterminatedArray
            }
            return valueStart..<source.index(after: closeIndex)
        case "\"":
            guard let string = try parseJSONString(in: source, from: valueStart, upTo: limit) else {
                throw JSONCEditError.unterminatedString
            }
            return string.range
        default:
            var end = valueStart
            while end < limit {
                let character = source[end]
                if character == "," || character == "}" || character == "]" ||
                    character == "\n" || character == "\r" {
                    break
                }
                if character == "/" {
                    let nextIndex = source.index(after: end)
                    if nextIndex < limit, source[nextIndex] == "/" || source[nextIndex] == "*" {
                        break
                    }
                }
                end = source.index(after: end)
            }
            while end > valueStart {
                let previous = source.index(before: end)
                guard source[previous].isWhitespace else { break }
                end = previous
            }
            guard end > valueStart else { throw JSONCEditError.valueNotFound }
            return valueStart..<end
        }
    }

    private static func matchingDelimiter(
        from openIndex: String.Index,
        open: Character,
        close: Character,
        in source: String,
        upTo limit: String.Index
    ) throws -> String.Index? {
        var depth = 0
        var index = openIndex
        while index < limit {
            let character = source[index]
            if character == "\"" {
                guard let string = try parseJSONString(in: source, from: index, upTo: limit) else {
                    throw JSONCEditError.unterminatedString
                }
                index = string.range.upperBound
                continue
            }
            if character == "/" {
                if try skipJSONCComment(in: source, index: &index, upTo: limit) {
                    continue
                }
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func skipJSONCTrivia(
        in source: String,
        index: inout String.Index,
        upTo limit: String.Index
    ) throws {
        while index < limit {
            if source[index].isWhitespace {
                index = source.index(after: index)
                continue
            }
            if try skipJSONCComment(in: source, index: &index, upTo: limit) {
                continue
            }
            return
        }
    }

    @discardableResult
    private static func skipJSONCComment(
        in source: String,
        index: inout String.Index,
        upTo limit: String.Index
    ) throws -> Bool {
        guard index < limit, source[index] == "/" else { return false }
        let nextIndex = source.index(after: index)
        guard nextIndex < limit else { return false }

        if source[nextIndex] == "/" {
            index = source.index(after: nextIndex)
            while index < limit, source[index] != "\n" {
                index = source.index(after: index)
            }
            return true
        }

        if source[nextIndex] == "*" {
            index = source.index(after: nextIndex)
            while index < limit {
                let followingIndex = source.index(after: index)
                if source[index] == "*", followingIndex < limit, source[followingIndex] == "/" {
                    index = source.index(after: followingIndex)
                    return true
                }
                index = followingIndex
            }
            throw JSONCEditError.unterminatedComment
        }

        return false
    }

    private static func parseJSONString(
        in source: String,
        from quoteIndex: String.Index,
        upTo limit: String.Index
    ) throws -> (value: String, range: Range<String.Index>)? {
        guard quoteIndex < limit, source[quoteIndex] == "\"" else { return nil }
        var value = ""
        var index = source.index(after: quoteIndex)
        var isEscaped = false
        while index < limit {
            let character = source[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return (value, quoteIndex..<source.index(after: index))
            } else {
                value.append(character)
            }
            index = source.index(after: index)
        }
        throw JSONCEditError.unterminatedString
    }

    private static func validateJSONC(_ source: String) throws {
        let data = try JSONCParser.preprocess(data: Data(source.utf8))
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }

    private enum JSONCEditError: LocalizedError {
        case rootObjectNotFound
        case unterminatedArray
        case unterminatedComment
        case unterminatedObject
        case unterminatedString
        case valueNotFound

        var errorDescription: String? {
            switch self {
            case .rootObjectNotFound:
                return "config file root object was not found"
            case .unterminatedArray:
                return "unterminated JSONC array"
            case .unterminatedComment:
                return "unterminated JSONC block comment"
            case .unterminatedObject:
                return "unterminated JSONC object"
            case .unterminatedString:
                return "unterminated JSONC string"
            case .valueNotFound:
                return "JSONC value was not found"
            }
        }
    }
}
