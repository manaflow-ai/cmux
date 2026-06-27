import Foundation

import CmuxFoundation

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
                    while index < source.endIndex, !source[index].isJSONCLineTerminator {
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
                    while index < source.endIndex, !source[index].isJSONCLineTerminator {
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
            if source[previous].isJSONCLineTerminator {
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
