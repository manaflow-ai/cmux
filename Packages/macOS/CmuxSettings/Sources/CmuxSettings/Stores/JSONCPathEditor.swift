import Foundation

struct JSONCPathEditor: Sendable {
    /// Synchronous editor input; the editor does not retain or share this object graph.
    struct EncodedValue: @unchecked Sendable { let rawValue: Any }
    enum EditError: Error, Equatable {
        case malformedObject
    }

    struct ObjectRange {
        let openBrace: String.Index
        let closeBrace: String.Index
        let properties: [PropertyRange]

        func property(named key: String) -> PropertyRange? {
            return properties.last { $0.key == key }
        }
    }

    struct PropertyRange {
        let key: String
        let keyStart: String.Index
        let valueStart: String.Index
        let valueEnd: String.Index
    }

    func set(path: [String], value: EncodedValue, in source: String) throws -> String {
        guard !path.isEmpty, let root = rootObject(in: source) else {
            throw EditError.malformedObject
        }
        return try setting(path: ArraySlice(path), value: value.rawValue, in: root, source: source)
    }

    func remove(path: [String], in source: String) throws -> String {
        guard !path.isEmpty, rootObject(in: source) != nil else {
            throw EditError.malformedObject
        }
        guard property(at: path, in: source) != nil else { return source }

        var updated = source
        // A parsed JSON object resolves duplicate keys to the last occurrence.
        // Remove every duplicate leaf so reset cannot expose a shadowed value.
        while property(at: path, in: updated) != nil {
            let next = try removingProperty(at: path, in: updated)
            guard next != updated else { break }
            updated = next
        }
        guard path.count > 1 else { return updated }

        // Match JSONPath's tidy-parent behavior while keeping comment-only
        // containers when pruning them would delete user-authored documentation.
        // If an ancestor key is duplicated, keep the now-empty effective object:
        // pruning it would expose an older shadowed section and change unrelated
        // authored content back into the effective configuration.
        for depth in stride(from: path.count - 1, through: 1, by: -1) {
            let ancestorPath = Array(path.prefix(depth))
            guard let ancestorObject = object(at: ancestorPath, in: updated),
                  ancestorObject.properties.isEmpty,
                  !containsComment(in: ancestorObject, source: updated),
                  let (parent, _) = parentAndPropertyIndex(at: ancestorPath, in: updated),
                  let ancestorKey = ancestorPath.last,
                  parent.properties.filter({ $0.key == ancestorKey }).count == 1 else {
                break
            }
            updated = try removingProperty(at: ancestorPath, in: updated)
        }
        return updated
    }

    private func setting(
        path: ArraySlice<String>,
        value: Any,
        in object: ObjectRange,
        source: String
    ) throws -> String {
        guard let key = path.first else { return source }
        if path.count == 1 {
            let valueJSON = try encodedJSON(value)
            if let property = object.property(named: key) {
                let indent = propertyLineIndent(property, in: source)
                let replacement = formatValueJSON(valueJSON, propertyIndent: indent, newline: preferredNewline(in: source))
                return replacing(source, from: property.valueStart, to: property.valueEnd, with: replacement)
            }
            return insertingProperty(key: key, valueJSON: valueJSON, into: object, in: source)
        }

        if let property = object.property(named: key) {
            let valueStart = skipWhitespaceAndComments(in: source, from: property.valueStart)
            if valueStart < source.endIndex,
               source[valueStart] == "{",
               let child = parseObject(in: source, at: valueStart) {
                return try setting(path: path.dropFirst(), value: value, in: child, source: source)
            }

            // JSONPath's native write semantics are "write wins": a scalar
            // intermediate is replaced with the object needed by the path.
            let nested = nestedObject(components: path.dropFirst(), value: value)
            let valueJSON = try encodedJSON(nested)
            let indent = propertyLineIndent(property, in: source)
            let replacement = formatValueJSON(valueJSON, propertyIndent: indent, newline: preferredNewline(in: source))
            return replacing(source, from: property.valueStart, to: property.valueEnd, with: replacement)
        }

        let nested = nestedObject(components: path.dropFirst(), value: value)
        return try insertingProperty(
            key: key,
            valueJSON: encodedJSON(nested),
            into: object,
            in: source
        )
    }

    private func nestedObject(components: ArraySlice<String>, value: Any) -> Any {
        guard let key = components.first else { return value }
        return [key: nestedObject(components: components.dropFirst(), value: value)]
    }

    private func encodedJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        guard let compact = String(data: data, encoding: .utf8) else {
            throw EditError.malformedObject
        }
        return prettyJSON(compact)
    }

    private func prettyJSON(_ compact: String) -> String {
        var result = ""
        var depth = 0
        var inString = false
        var escaped = false
        var index = compact.startIndex
        while index < compact.endIndex {
            let character = compact[index]
            if inString {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = compact.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
            } else if character == "{" || character == "[" {
                result.append(character)
                let next = compact.index(after: index)
                let closesImmediately = next < compact.endIndex
                    && ((character == "{" && compact[next] == "}")
                        || (character == "[" && compact[next] == "]"))
                depth += 1
                if !closesImmediately {
                    result += "\n" + String(repeating: "  ", count: depth)
                }
            } else if character == "}" || character == "]" {
                depth = max(0, depth - 1)
                let previous = index > compact.startIndex ? compact[compact.index(before: index)] : Character(" ")
                let openedImmediately = (character == "}" && previous == "{")
                    || (character == "]" && previous == "[")
                if !openedImmediately {
                    result += "\n" + String(repeating: "  ", count: depth)
                }
                result.append(character)
            } else if character == "," {
                result += ",\n" + String(repeating: "  ", count: depth)
            } else if character == ":" {
                result += ": "
            } else {
                result.append(character)
            }
            index = compact.index(after: index)
        }
        return result
    }

    private func insertingProperty(
        key: String,
        valueJSON: String,
        into object: ObjectRange,
        in source: String
    ) -> String {
        var updated = source
        var closeOffset = source.distance(from: source.startIndex, to: object.closeBrace)
        let newline = preferredNewline(in: source)
        let closingIndent = indentationBeforeLine(containing: object.closeBrace, in: source)
        let indent = propertyIndent(for: object, in: source)
        let trailingCommaStyle = hasTrailingComma(after: object.properties.last, before: object.closeBrace, in: source)
        let property = "\(indent)\(quotedJSONString(key)): \(formatValueJSON(valueJSON, propertyIndent: indent, newline: newline))"
            + (trailingCommaStyle ? "," : "")

        if let last = object.properties.last, !trailingCommaStyle {
            let commaOffset = source.distance(from: source.startIndex, to: last.valueEnd)
            let commaIndex = updated.index(updated.startIndex, offsetBy: commaOffset)
            updated.insert(",", at: commaIndex)
            if commaOffset <= closeOffset { closeOffset += 1 }
        }

        let closeIndex = updated.index(updated.startIndex, offsetBy: closeOffset)
        let closeLineStart = startOfLine(containing: closeIndex, in: updated)
        let closeIsOnOwnLine = updated[closeLineStart..<closeIndex].allSatisfy { $0 == " " || $0 == "\t" }
        if closeIsOnOwnLine {
            updated.insert(contentsOf: "\(property)\(newline)", at: closeLineStart)
        } else {
            updated.insert(
                contentsOf: "\(newline)\(property)\(newline)\(closingIndent)",
                at: closeIndex
            )
        }
        return updated
    }

    private func removingProperty(at path: [String], in source: String) throws -> String {
        guard let (parent, childIndex) = parentAndPropertyIndex(at: path, in: source, selectingLast: false) else {
            return source
        }
        let child = parent.properties[childIndex]
        let lineStart = startOfLine(containing: child.keyStart, in: source)
        let startsOwnLine = source[lineStart..<child.keyStart].allSatisfy { $0 == " " || $0 == "\t" }
        let removeStart = startsOwnLine ? lineStart : child.keyStart

        if let comma = followingComma(after: child.valueEnd, before: parent.closeBrace, in: source) {
            var removeEnd = source.index(after: comma)
            removeEnd = attachedLineCommentEnd(from: removeEnd, in: source, consumeNewline: startsOwnLine)
            return replacing(source, from: removeStart, to: removeEnd, with: "")
        }

        var removeEnd = attachedLineCommentEnd(
            from: child.valueEnd,
            in: source,
            consumeNewline: startsOwnLine
        )
        if startsOwnLine, removeEnd == child.valueEnd,
           removeEnd < source.endIndex,
           isLineTerminator(source[removeEnd]) {
            removeEnd = indexAfterLineTerminator(at: removeEnd, in: source)
        }

        guard childIndex > 0 else {
            return replacing(source, from: removeStart, to: removeEnd, with: "")
        }
        let previous = parent.properties[childIndex - 1]
        guard let separator = followingComma(after: previous.valueEnd, before: child.keyStart, in: source) else {
            throw EditError.malformedObject
        }

        // Remove the separator without swallowing comments/trivia between the
        // previous property and the removed entry.
        var withoutSeparator = source
        withoutSeparator.remove(at: separator)
        let startOffset = source.distance(from: source.startIndex, to: removeStart)
        let endOffset = source.distance(from: source.startIndex, to: removeEnd)
        let adjustedStart = startOffset - (separator < removeStart ? 1 : 0)
        let adjustedEnd = endOffset - (separator < removeEnd ? 1 : 0)
        let start = withoutSeparator.index(withoutSeparator.startIndex, offsetBy: adjustedStart)
        let end = withoutSeparator.index(withoutSeparator.startIndex, offsetBy: adjustedEnd)
        withoutSeparator.replaceSubrange(start..<end, with: "")
        return withoutSeparator
    }

    private func parentAndPropertyIndex(
        at path: [String],
        in source: String,
        selectingLast: Bool = true
    ) -> (ObjectRange, Int)? {
        guard !path.isEmpty, var object = rootObject(in: source) else { return nil }
        for component in path.dropLast() {
            let property = selectingLast
                ? object.property(named: component)
                : object.properties.first { $0.key == component }
            guard let property else { return nil }
            let valueStart = skipWhitespaceAndComments(in: source, from: property.valueStart)
            guard valueStart < source.endIndex,
                  source[valueStart] == "{",
                  let child = parseObject(in: source, at: valueStart) else { return nil }
            object = child
        }
        let index = selectingLast
            ? object.properties.lastIndex { $0.key == path.last }
            : object.properties.firstIndex { $0.key == path.last }
        guard let index else { return nil }
        return (object, index)
    }

    private func property(at path: [String], in source: String) -> PropertyRange? {
        guard let (parent, index) = parentAndPropertyIndex(at: path, in: source) else { return nil }
        return parent.properties[index]
    }

    private func object(at path: [String], in source: String) -> ObjectRange? {
        guard var object = rootObject(in: source) else { return nil }
        for component in path {
            guard let property = object.property(named: component) else { return nil }
            let start = skipWhitespaceAndComments(in: source, from: property.valueStart)
            guard start < source.endIndex,
                  source[start] == "{",
                  let child = parseObject(in: source, at: start) else { return nil }
            object = child
        }
        return object
    }

    private func rootObject(in source: String) -> ObjectRange? {
        var index = skipWhitespaceAndComments(in: source, from: source.startIndex)
        if index < source.endIndex, source[index] == "\u{feff}" {
            index = source.index(after: index)
            index = skipWhitespaceAndComments(in: source, from: index)
        }
        guard index < source.endIndex, source[index] == "{" else { return nil }
        return parseObject(in: source, at: index)
    }

    private func parseObject(in source: String, at openBrace: String.Index) -> ObjectRange? {
        guard openBrace < source.endIndex, source[openBrace] == "{",
              let closeBrace = matchingContainerEnd(in: source, at: openBrace) else { return nil }
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
                  let parsedKey = parseJSONString(in: source, at: index) else { return nil }
            index = skipWhitespaceAndComments(in: source, from: parsedKey.end)
            guard index < closeBrace, source[index] == ":" else { return nil }
            index = source.index(after: index)
            let valueStart = skipWhitespaceAndComments(in: source, from: index)
            guard valueStart < closeBrace,
                  let valueEnd = skipValue(in: source, from: valueStart) else { return nil }
            properties.append(PropertyRange(
                key: parsedKey.value,
                keyStart: parsedKey.start,
                valueStart: valueStart,
                valueEnd: valueEnd
            ))
            index = valueEnd
        }
    }

    private func matchingContainerEnd(in source: String, at start: String.Index) -> String.Index? {
        let opening = source[start]
        let closing: Character
        switch opening {
        case "{": closing = "}"
        case "[": closing = "]"
        default: return nil
        }
        var stack: [Character] = [closing]
        var index = source.index(after: start)
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                guard let end = parseJSONString(in: source, at: index)?.end else { return nil }
                index = end
                continue
            }
            if character == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" {
                    index = source.index(after: next)
                    while index < source.endIndex, !isLineTerminator(source[index]) {
                        index = source.index(after: index)
                    }
                    continue
                }
                if next < source.endIndex, source[next] == "*" {
                    index = source.index(after: next)
                    var closed = false
                    while index < source.endIndex {
                        let following = source.index(after: index)
                        if source[index] == "*", following < source.endIndex, source[following] == "/" {
                            index = source.index(after: following)
                            closed = true
                            break
                        }
                        index = following
                    }
                    if !closed { return nil }
                    continue
                }
            }
            if character == "{" { stack.append("}") }
            else if character == "[" { stack.append("]") }
            else if character == stack.last {
                stack.removeLast()
                if stack.isEmpty { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func skipValue(in source: String, from start: String.Index) -> String.Index? {
        guard start < source.endIndex else { return nil }
        let character = source[start]
        if character == "{" || character == "[" {
            guard let end = matchingContainerEnd(in: source, at: start) else { return nil }
            return source.index(after: end)
        }
        if character == "\"" { return parseJSONString(in: source, at: start)?.end }
        var index = start
        while index < source.endIndex {
            let current = source[index]
            if current == "," || current == "}" || current == "]" || current.isWhitespace { return index }
            if current == "/" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "/" || source[next] == "*" { return index }
            }
            index = source.index(after: index)
        }
        return index
    }

    private func parseJSONString(
        in source: String,
        at start: String.Index
    ) -> (start: String.Index, end: String.Index, value: String)? {
        guard start < source.endIndex, source[start] == "\"" else { return nil }
        var index = source.index(after: start)
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" {
                let end = source.index(after: index)
                let raw = String(source[start..<end])
                guard let data = raw.data(using: .utf8),
                      let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                return (start, end, value)
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func skipWhitespaceAndComments(in source: String, from start: String.Index) -> String.Index {
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
                    while index < source.endIndex, !isLineTerminator(source[index]) {
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

    private func followingComma(
        after start: String.Index,
        before limit: String.Index,
        in source: String
    ) -> String.Index? {
        let index = skipWhitespaceAndComments(in: source, from: start)
        return index < limit && source[index] == "," ? index : nil
    }

    private func hasTrailingComma(
        after property: PropertyRange?,
        before closeBrace: String.Index,
        in source: String
    ) -> Bool {
        guard let property else { return false }
        return followingComma(after: property.valueEnd, before: closeBrace, in: source) != nil
    }

    private func containsComment(in object: ObjectRange, source: String) -> Bool {
        let start = source.index(after: object.openBrace)
        let body = source[start..<object.closeBrace]
        return body.contains("//") || body.contains("/*")
    }

    private func attachedLineCommentEnd(
        from start: String.Index,
        in source: String,
        consumeNewline: Bool
    ) -> String.Index {
        var index = start
        while index < source.endIndex, source[index] == " " || source[index] == "\t" {
            index = source.index(after: index)
        }
        if index < source.endIndex, source[index...].hasPrefix("//") {
            while index < source.endIndex, !isLineTerminator(source[index]) {
                index = source.index(after: index)
            }
        }
        if consumeNewline, index < source.endIndex, isLineTerminator(source[index]) {
            return indexAfterLineTerminator(at: index, in: source)
        }
        return index
    }

    private func indexAfterLineTerminator(at index: String.Index, in source: String) -> String.Index {
        // Swift models CRLF as one extended grapheme cluster on current toolchains.
        source.index(after: index)
    }

    private func propertyIndent(for object: ObjectRange, in source: String) -> String {
        let closingIndent = indentationBeforeLine(containing: object.closeBrace, in: source)
        if let first = object.properties.first {
            let lineStart = startOfLine(containing: first.keyStart, in: source)
            if source[lineStart..<first.keyStart].allSatisfy({ $0 == " " || $0 == "\t" }) {
                let existing = String(source[lineStart..<first.keyStart])
                if existing.count > closingIndent.count { return existing }
            }
        }
        return closingIndent + "  "
    }

    private func propertyLineIndent(_ property: PropertyRange, in source: String) -> String {
        let lineStart = startOfLine(containing: property.keyStart, in: source)
        if source[lineStart..<property.keyStart].allSatisfy({ $0 == " " || $0 == "\t" }) {
            return String(source[lineStart..<property.keyStart])
        }
        return ""
    }

    private func indentationBeforeLine(containing index: String.Index, in source: String) -> String {
        let lineStart = startOfLine(containing: index, in: source)
        var cursor = lineStart
        var indentation = ""
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
            indentation.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        return indentation
    }

    private func startOfLine(containing index: String.Index, in source: String) -> String.Index {
        var lineStart = index
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if isLineTerminator(source[previous]) { break }
            lineStart = previous
        }
        return lineStart
    }

    private func preferredNewline(in source: String) -> String {
        if source.contains("\r\n") { return "\r\n" }
        if source.contains("\r") { return "\r" }
        return "\n"
    }

    private func isLineTerminator(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar == "\n" || scalar == "\r"
    }

    private func formatValueJSON(
        _ valueJSON: String,
        propertyIndent: String,
        newline: String
    ) -> String {
        let normalized = newline == "\n" ? valueJSON : valueJSON.replacingOccurrences(of: "\n", with: newline)
        let lines = normalized.components(separatedBy: newline)
        guard let first = lines.first else { return normalized }
        return ([first] + lines.dropFirst().map { propertyIndent + $0 }).joined(separator: newline)
    }

    private func quotedJSONString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(value)\""
    }

    private func replacing(
        _ source: String,
        from start: String.Index,
        to end: String.Index,
        with replacement: String
    ) -> String {
        var updated = source
        updated.replaceSubrange(start..<end, with: replacement)
        return updated
    }
}
