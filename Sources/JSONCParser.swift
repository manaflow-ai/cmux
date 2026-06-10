import Foundation

enum JSONCParser {
    static func preprocess(data: Data) throws -> Data {
        let source = try sourceString(from: data)
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let stripped = try stripComments(from: withoutBOM)
        let normalized = try stripTrailingCommas(from: stripped)
        return Data(normalized.utf8)
    }

    static func source(data: Data) throws -> (text: String, encoding: String.Encoding) {
        if let encoding = detectedJSONEncoding(for: data),
           let source = String(data: data, encoding: encoding) {
            return (source, encoding)
        }
        if let source = String(data: data, encoding: .utf8) {
            return (source, .utf8)
        }

        var convertedString: NSString?
        var usedLossyConversion = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding.utf16BigEndian.rawValue,
                    String.Encoding.utf16LittleEndian.rawValue,
                    String.Encoding.utf32BigEndian.rawValue,
                    String.Encoding.utf32LittleEndian.rawValue,
                ],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &convertedString,
            usedLossyConversion: &usedLossyConversion
        )

        if let convertedString, !usedLossyConversion.boolValue {
            let stringEncoding = encoding == 0 ? String.Encoding.utf8 : String.Encoding(rawValue: encoding)
            return (convertedString as String, stringEncoding)
        }
        if encoding != 0, !usedLossyConversion.boolValue {
            let stringEncoding = String.Encoding(rawValue: encoding)
            if let string = String(data: data, encoding: stringEncoding) {
                return (string, stringEncoding)
            }
        }
        throw JSONCError.invalidTextEncoding
    }

    private static func sourceString(from data: Data) throws -> String {
        try source(data: data).text
    }

    private static func detectedJSONEncoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        guard bytes.count >= 4 else { return nil }

        switch (bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0) {
        case (true, true, true, false):
            return .utf32BigEndian
        case (false, true, true, true):
            return .utf32LittleEndian
        case (true, false, true, false):
            return .utf16BigEndian
        case (false, true, false, true):
            return .utf16LittleEndian
        default:
            return nil
        }
    }

    static func isLineTerminator(_ character: Character) -> Bool {
        // Swift treats "\r\n" as a single extended grapheme cluster, so comparing
        // against "\n" alone misses CRLF line endings and would let line comments
        // run to end-of-file. Match any character whose first scalar is CR or LF.
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar == "\n" || scalar == "\r"
    }

    private static func stripComments(from source: String) throws -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "/" {
                let nextIndex = source.index(after: index)
                if nextIndex < source.endIndex {
                    let next = source[nextIndex]
                    if next == "/" {
                        index = source.index(after: nextIndex)
                        while index < source.endIndex && !JSONCParser.isLineTerminator(source[index]) {
                            index = source.index(after: index)
                        }
                        continue
                    }
                    if next == "*" {
                        index = source.index(after: nextIndex)
                        var didClose = false
                        while index < source.endIndex {
                            let current = source[index]
                            let followingIndex = source.index(after: index)
                            if current == "*" && followingIndex < source.endIndex && source[followingIndex] == "/" {
                                index = source.index(after: followingIndex)
                                didClose = true
                                break
                            }
                            index = followingIndex
                        }
                        guard didClose else {
                            throw JSONCError.unterminatedBlockComment
                        }
                        continue
                    }
                }
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    private static func stripTrailingCommas(from source: String) throws -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false
        var lastSignificantCharacter: Character?

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                    lastSignificantCharacter = character
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = source.index(after: index)
                while lookahead < source.endIndex && source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex && (source[lookahead] == "}" || source[lookahead] == "]") {
                    if lastSignificantCharacter == nil ||
                        lastSignificantCharacter == "," ||
                        lastSignificantCharacter == "{" ||
                        lastSignificantCharacter == "[" ||
                        lastSignificantCharacter == ":" {
                        throw JSONCError.invalidTrailingComma
                    }
                    index = source.index(after: index)
                    continue
                }
            }

            result.append(character)
            if !character.isWhitespace {
                lastSignificantCharacter = character
            }
            index = source.index(after: index)
        }

        return result
    }

    private enum JSONCError: LocalizedError {
        case invalidTextEncoding
        case invalidTrailingComma
        case unterminatedBlockComment

        var errorDescription: String? {
            switch self {
            case .invalidTextEncoding:
                return "config file text encoding is not supported"
            case .invalidTrailingComma:
                return "invalid trailing comma"
            case .unterminatedBlockComment:
                return "unterminated block comment"
            }
        }
    }
}

enum JSONCObjectEditor {
    static func setNestedObjectProperty(
        parentKey: String,
        childKey: String,
        childValueJSON: String,
        in source: String
    ) -> String? {
        guard let root = rootObject(in: source) else { return nil }
        let newline = preferredNewline(in: source)

        if let parent = root.property(named: parentKey) {
            let parentValueStart = skipWhitespaceAndComments(in: source, from: parent.valueStart)
            guard parentValueStart < source.endIndex else { return nil }
            if source[parentValueStart] == "{",
               let parentObject = parseObject(in: source, at: parentValueStart) {
                if let child = parentObject.property(named: childKey) {
                    let childIndent = indentationBeforeLine(containing: child.keyStart, in: source)
                    let replacement = withPreferredNewline(
                        valueJSONForProperty(childValueJSON, propertyIndent: childIndent),
                        newline: newline
                    )
                    return replacing(source, from: child.valueStart, to: child.valueEnd, with: replacement)
                }

                let childIndent = propertyIndent(for: parentObject, in: source)
                let childProperty = propertyText(key: childKey, valueJSON: childValueJSON, indent: childIndent)
                return inserting(childProperty, into: parentObject, in: source)
            }

            let parentIndent = indentationBeforeLine(containing: parent.keyStart, in: source)
            let childIndent = parentIndent + "  "
            let childProperty = propertyText(key: childKey, valueJSON: childValueJSON, indent: childIndent)
            let replacement = withPreferredNewline("{\n\(childProperty)\n\(parentIndent)}", newline: newline)
            return replacing(source, from: parent.valueStart, to: parent.valueEnd, with: replacement)
        }

        let parentIndent = propertyIndent(for: root, in: source)
        let childIndent = parentIndent + "  "
        let childProperty = propertyText(key: childKey, valueJSON: childValueJSON, indent: childIndent)
        let parentProperty = "\(parentIndent)\(quotedJSONString(parentKey)): {\n\(childProperty)\n\(parentIndent)}"
        return inserting(parentProperty, into: root, in: source)
    }

    private struct ObjectRange {
        let openBrace: String.Index
        let closeBrace: String.Index
        let properties: [PropertyRange]

        func property(named key: String) -> PropertyRange? {
            properties.first { $0.key == key }
        }
    }

    private struct PropertyRange {
        let key: String
        let keyStart: String.Index
        let valueStart: String.Index
        let valueEnd: String.Index
    }

    private static func rootObject(in source: String) -> ObjectRange? {
        var index = skipWhitespaceAndComments(in: source, from: source.startIndex)
        if index < source.endIndex, source[index] == "\u{feff}" {
            index = source.index(after: index)
            index = skipWhitespaceAndComments(in: source, from: index)
        }
        guard index < source.endIndex, source[index] == "{" else { return nil }
        return parseObject(in: source, at: index)
    }

    private static func parseObject(in source: String, at openBrace: String.Index) -> ObjectRange? {
        guard openBrace < source.endIndex, source[openBrace] == "{" else { return nil }
        guard let closeBrace = matchingContainerEnd(in: source, at: openBrace) else { return nil }

        var properties: [PropertyRange] = []
        var index = source.index(after: openBrace)
        while true {
            index = skipWhitespaceAndComments(in: source, from: index)
            guard index < closeBrace else {
                return ObjectRange(openBrace: openBrace, closeBrace: closeBrace, properties: properties)
            }
            if source[index] == "," {
                index = source.index(after: index)
                continue
            }
            guard source[index] == "\"",
                  let parsedKey = parseJSONString(in: source, at: index) else {
                return nil
            }

            index = skipWhitespaceAndComments(in: source, from: parsedKey.end)
            guard index < closeBrace, source[index] == ":" else { return nil }
            index = source.index(after: index)
            let valueStart = skipWhitespaceAndComments(in: source, from: index)
            guard valueStart < closeBrace,
                  let valueEnd = skipValue(in: source, from: valueStart) else {
                return nil
            }

            properties.append(PropertyRange(
                key: parsedKey.value,
                keyStart: parsedKey.start,
                valueStart: valueStart,
                valueEnd: valueEnd
            ))
            index = valueEnd
        }
    }

    private static func matchingContainerEnd(in source: String, at start: String.Index) -> String.Index? {
        let opening = source[start]
        let closing: Character
        if opening == "{" {
            closing = "}"
        } else if opening == "[" {
            closing = "]"
        } else {
            return nil
        }

        var stack: [Character] = [closing]
        var index = source.index(after: start)
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                guard let stringEnd = parseJSONString(in: source, at: index)?.end else { return nil }
                index = stringEnd
                continue
            }
            if character == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" {
                    index = source.index(after: next)
                    while index < source.endIndex, !JSONCParser.isLineTerminator(source[index]) {
                        index = source.index(after: index)
                    }
                    continue
                }
                if next < source.endIndex, source[next] == "*" {
                    index = source.index(after: next)
                    while index < source.endIndex {
                        let following = source.index(after: index)
                        if source[index] == "*", following < source.endIndex, source[following] == "/" {
                            index = source.index(after: following)
                            break
                        }
                        index = following
                    }
                    continue
                }
            }
            if character == "{" {
                stack.append("}")
            } else if character == "[" {
                stack.append("]")
            } else if character == stack.last {
                stack.removeLast()
                if stack.isEmpty {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func skipValue(in source: String, from start: String.Index) -> String.Index? {
        guard start < source.endIndex else { return nil }
        let character = source[start]
        if character == "{" || character == "[" {
            guard let end = matchingContainerEnd(in: source, at: start) else { return nil }
            return source.index(after: end)
        }
        if character == "\"" {
            return parseJSONString(in: source, at: start)?.end
        }

        var index = start
        while index < source.endIndex {
            let current = source[index]
            if current == "," || current == "}" || current == "]" || current.isWhitespace {
                return index
            }
            if current == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" || source[next] == "*" {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return index
    }

    private static func parseJSONString(in source: String, at start: String.Index) -> (start: String.Index, end: String.Index, value: String)? {
        guard start < source.endIndex, source[start] == "\"" else { return nil }
        var index = source.index(after: start)
        var isEscaped = false
        while index < source.endIndex {
            let character = source[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let end = source.index(after: index)
                let raw = String(source[start..<end])
                guard let data = raw.data(using: .utf8),
                      let value = try? JSONDecoder().decode(String.self, from: data) else {
                    return nil
                }
                return (start, end, value)
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func skipWhitespaceAndComments(in source: String, from start: String.Index) -> String.Index {
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace || character == "\u{feff}" {
                index = source.index(after: index)
                continue
            }
            if character == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" {
                    index = source.index(after: next)
                    while index < source.endIndex, !JSONCParser.isLineTerminator(source[index]) {
                        index = source.index(after: index)
                    }
                    continue
                }
                if next < source.endIndex, source[next] == "*" {
                    index = source.index(after: next)
                    while index < source.endIndex {
                        let following = source.index(after: index)
                        if source[index] == "*", following < source.endIndex, source[following] == "/" {
                            index = source.index(after: following)
                            break
                        }
                        index = following
                    }
                    continue
                }
            }
            return index
        }
        return index
    }

    private static func propertyIndent(for object: ObjectRange, in source: String) -> String {
        indentationBeforeLine(containing: object.closeBrace, in: source) + "  "
    }

    private static func indentationBeforeLine(containing index: String.Index, in source: String) -> String {
        var lineStart = index
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if JSONCParser.isLineTerminator(source[previous]) {
                break
            }
            lineStart = previous
        }

        var indentation = ""
        var cursor = lineStart
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == " " || character == "\t" {
                indentation.append(character)
                cursor = source.index(after: cursor)
                continue
            }
            break
        }
        return indentation
    }

    private static func propertyText(key: String, valueJSON: String, indent: String) -> String {
        "\(indent)\(quotedJSONString(key)): \(valueJSONForProperty(valueJSON, propertyIndent: indent))"
    }

    private static func quotedJSONString(_ value: String) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func valueJSONForProperty(_ valueJSON: String, propertyIndent: String) -> String {
        let lines = valueJSON.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return valueJSON }
        return ([first] + lines.dropFirst().map { propertyIndent + $0 }).joined(separator: "\n")
    }

    private static func preferredNewline(in source: String) -> String {
        if source.contains("\r\n") {
            return "\r\n"
        }
        if source.contains("\r") {
            return "\r"
        }
        return "\n"
    }

    private static func withPreferredNewline(_ text: String, newline: String) -> String {
        guard newline != "\n" else { return text }
        return text.replacingOccurrences(of: "\n", with: newline)
    }

    private static func replacing(
        _ source: String,
        from start: String.Index,
        to end: String.Index,
        with replacement: String
    ) -> String {
        var updated = source
        updated.replaceSubrange(start..<end, with: replacement)
        return updated
    }

    private static func inserting(_ propertyText: String, into object: ObjectRange, in source: String) -> String {
        var updated = source
        let closeOffset = source.distance(from: source.startIndex, to: object.closeBrace)
        let closingIndent = indentationBeforeLine(containing: object.closeBrace, in: source)
        let newline = preferredNewline(in: source)
        let normalizedPropertyText = withPreferredNewline(propertyText, newline: newline)

        if let lastProperty = object.properties.last,
           !hasTrailingComma(after: lastProperty, before: object.closeBrace, in: source) {
            let commaOffset = source.distance(from: source.startIndex, to: lastProperty.valueEnd)
            let commaIndex = updated.index(updated.startIndex, offsetBy: commaOffset)
            updated.insert(",", at: commaIndex)
        }

        let adjustedCloseOffset = closeOffset + (object.properties.isEmpty || hasTrailingComma(after: object.properties.last, before: object.closeBrace, in: source) ? 0 : 1)
        let closeIndex = updated.index(updated.startIndex, offsetBy: adjustedCloseOffset)
        updated.insert(contentsOf: "\(newline)\(normalizedPropertyText)\(newline)\(closingIndent)", at: closeIndex)
        return updated
    }

    private static func hasTrailingComma(after property: PropertyRange?, before closeBrace: String.Index, in source: String) -> Bool {
        guard let property else { return false }
        let index = skipWhitespaceAndComments(in: source, from: property.valueEnd)
        return index < closeBrace && source[index] == ","
    }
}
