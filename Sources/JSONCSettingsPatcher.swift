import Foundation

enum JSONCSettingsPatcher {
    static func setting(_ path: String, to value: Any, in source: String) throws -> String {
        let components = path.split(separator: ".").map(String.init)
        guard components.count == 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let renderedValue = try renderJSON(value)
        let scanner = Scanner(source: source)
        let root = try scanner.rootObject()
        let sectionKey = components[0]
        let settingKey = components[1]

        if let section = try scanner.property(sectionKey, in: root) {
            if let sectionObject = try scanner.object(at: section.valueRange.lowerBound) {
                if let setting = try scanner.property(settingKey, in: sectionObject) {
                    return replacing(setting.valueRange, with: renderedValue, in: source)
                }
                return inserting(settingKey, valueJSON: renderedValue, in: sectionObject, source: source)
            }

            let replacement = objectJSON(setting: settingKey, valueJSON: renderedValue)
            return replacing(section.valueRange, with: replacement, in: source)
        }

        let valueJSON = objectJSON(setting: settingKey, valueJSON: renderedValue)
        return inserting(sectionKey, valueJSON: valueJSON, in: root, source: source)
    }

    private static func objectJSON(setting: String, valueJSON: String) -> String {
        "{\n    \(renderString(setting)): \(valueJSON)\n  }"
    }

    private static func inserting(
        _ key: String,
        valueJSON: String,
        in object: ObjectInfo,
        source: String
    ) -> String {
        let indent = lineIndent(in: source, at: object.open)
        let childIndent = indent + "  "
        if object.hasProperties {
            let closeIndent = lineIndent(in: source, at: object.close)
            let closeChildIndent = closeIndent + "  "
            let insertion = ",\n\(closeChildIndent)\(renderString(key)): \(valueJSON)\n\(closeIndent)"
            return replacing(object.close..<object.close, with: insertion, in: source)
        }

        let insertion = "\n\(childIndent)\(renderString(key)): \(valueJSON)"
        let insertAt = source.index(after: object.open)
        return replacing(insertAt..<insertAt, with: insertion, in: source)
    }

    private static func replacing(
        _ range: Range<String.Index>,
        with replacement: String,
        in source: String
    ) -> String {
        var output = source
        output.replaceSubrange(range, with: replacement)
        return output
    }

    private static func lineIndent(in source: String, at index: String.Index) -> String {
        var lineStart = index
        while lineStart > source.startIndex {
            let previous = source.index(before: lineStart)
            if source[previous] == "\n" { break }
            lineStart = previous
        }

        var cursor = lineStart
        var indent = ""
        while cursor < index {
            let character = source[cursor]
            guard character == " " || character == "\t" else { break }
            indent.append(character)
            cursor = source.index(after: cursor)
        }
        return indent
    }

    private static func renderJSON(_ value: Any) throws -> String {
        if value is NSNull {
            return "null"
        }
        if let value = value as? Bool {
            return value ? "true" : "false"
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Double {
            guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            return String(value)
        }
        if let value = value as? String {
            return renderString(value)
        }

        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        options.insert(.withoutEscapingSlashes)
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return string
    }

    private static func renderString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let renderedArray = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(renderedArray.dropFirst().dropLast())
    }
}

private struct ObjectInfo {
    let open: String.Index
    let close: String.Index
    let hasProperties: Bool
}

private struct PropertyInfo {
    let valueRange: Range<String.Index>
}

private struct Scanner {
    let source: String

    func rootObject() throws -> ObjectInfo {
        let start = skipTrivia(from: source.startIndex, limit: source.endIndex)
        guard start < source.endIndex, source[start] == "{" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let object = try object(at: start) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    func object(at index: String.Index) throws -> ObjectInfo? {
        let open = skipTrivia(from: index, limit: source.endIndex)
        guard open < source.endIndex, source[open] == "{" else { return nil }
        let close = try matchingClose(for: open, open: "{", close: "}")
        return ObjectInfo(open: open, close: close, hasProperties: try hasProperty(in: open, close: close))
    }

    func property(_ key: String, in object: ObjectInfo) throws -> PropertyInfo? {
        var cursor = source.index(after: object.open)
        while true {
            cursor = skipTrivia(from: cursor, limit: object.close)
            guard cursor < object.close else { return nil }
            guard source[cursor] == "\"" else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let nameEnd = try stringEnd(from: cursor)
            let name = String(source[source.index(after: cursor)..<source.index(before: nameEnd)])
            var colon = skipTrivia(from: nameEnd, limit: object.close)
            guard colon < object.close, source[colon] == ":" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            colon = source.index(after: colon)

            let valueStart = skipTrivia(from: colon, limit: object.close)
            let valueEnd = try valueEnd(from: valueStart, limit: object.close)
            if name == key {
                return PropertyInfo(valueRange: valueStart..<valueEnd)
            }

            cursor = skipTrivia(from: valueEnd, limit: object.close)
            if cursor < object.close, source[cursor] == "," {
                cursor = source.index(after: cursor)
            }
        }
    }

    private func hasProperty(in open: String.Index, close: String.Index) throws -> Bool {
        let first = skipTrivia(from: source.index(after: open), limit: close)
        return first < close && source[first] == "\""
    }

    private func skipTrivia(from index: String.Index, limit: String.Index) -> String.Index {
        var cursor = index
        while cursor < limit {
            if source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
                continue
            }
            guard source[cursor] == "/" else { break }
            let next = source.index(after: cursor)
            guard next < limit else { break }
            if source[next] == "/" {
                cursor = source.index(after: next)
                while cursor < limit, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if source[next] == "*" {
                cursor = source.index(after: next)
                while cursor < limit {
                    let following = source.index(after: cursor)
                    if source[cursor] == "*", following < limit, source[following] == "/" {
                        cursor = source.index(after: following)
                        break
                    }
                    cursor = following
                }
                continue
            }
            break
        }
        return cursor
    }

    private func valueEnd(from index: String.Index, limit: String.Index) throws -> String.Index {
        guard index < limit else { throw CocoaError(.fileReadCorruptFile) }
        switch source[index] {
        case "\"":
            return try stringEnd(from: index)
        case "{":
            return source.index(after: try matchingClose(for: index, open: "{", close: "}"))
        case "[":
            return source.index(after: try matchingClose(for: index, open: "[", close: "]"))
        default:
            var cursor = index
            var end = index
            while cursor < limit {
                let character = source[cursor]
                if character == "," || character == "}" || character == "]" {
                    break
                }
                if character == "/" {
                    let next = source.index(after: cursor)
                    if next < limit, source[next] == "/" || source[next] == "*" {
                        break
                    }
                }
                if !character.isWhitespace {
                    end = source.index(after: cursor)
                }
                cursor = source.index(after: cursor)
            }
            guard end > index else { throw CocoaError(.fileReadCorruptFile) }
            return end
        }
    }

    private func stringEnd(from quote: String.Index) throws -> String.Index {
        var cursor = source.index(after: quote)
        var escaped = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return source.index(after: cursor)
            }
            cursor = source.index(after: cursor)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func matchingClose(for openIndex: String.Index, open: Character, close: Character) throws -> String.Index {
        var cursor = openIndex
        var depth = 0
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\"" {
                cursor = try stringEnd(from: cursor)
                continue
            }
            if character == "/" {
                let afterTrivia = skipTrivia(from: cursor, limit: source.endIndex)
                if afterTrivia != cursor {
                    cursor = afterTrivia
                    continue
                }
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor = source.index(after: cursor)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
