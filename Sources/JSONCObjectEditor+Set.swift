import Foundation

// MARK: - String property setting (comment-preserving)

extension JSONCObjectEditor {
    enum SetPropertyError: Error, Equatable {
        case malformedObject
        case nonObjectPathSegment(String)
    }

    /// Sets a nested string property in a JSONC object source, preserving all
    /// comments and formatting outside the inserted or replaced entry.
    static func setNestedStringProperty(
        objectPath: [String],
        key: String,
        value: String,
        in source: String
    ) throws -> String {
        guard (try? JSONCParser.preprocess(data: Data(source.utf8))).flatMap({
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) != nil else {
            throw SetPropertyError.malformedObject
        }
        guard let root = rootObject(in: source) else {
            throw SetPropertyError.malformedObject
        }
        let valueJSON = setQuotedJSONString(value)
        return try settingStringProperty(
            objectPath: objectPath,
            key: key,
            valueJSON: valueJSON,
            inObject: root,
            source: source
        )
    }

    private static func settingStringProperty(
        objectPath: [String],
        key: String,
        valueJSON: String,
        inObject object: ObjectRange,
        source: String
    ) throws -> String {
        guard let nextKey = objectPath.first else {
            if let property = object.property(named: key) {
                return replacing(source, from: property.valueStart, to: property.valueEnd, with: valueJSON)
            }

            let indent = setPropertyIndent(for: object, in: source)
            let property = setPropertyText(key: key, valueJSON: valueJSON, indent: indent)
            return setInserting(property, into: object, in: source)
        }

        if let nextProperty = object.property(named: nextKey) {
            let valueStart = skipWhitespaceAndComments(in: source, from: nextProperty.valueStart)
            guard valueStart < source.endIndex,
                  source[valueStart] == "{",
                  let childObject = parseObject(in: source, at: valueStart) else {
                throw SetPropertyError.nonObjectPathSegment(nextKey)
            }
            return try settingStringProperty(
                objectPath: Array(objectPath.dropFirst()),
                key: key,
                valueJSON: valueJSON,
                inObject: childObject,
                source: source
            )
        }

        let indent = setPropertyIndent(for: object, in: source)
        let nestedValueJSON = nestedObjectValueJSON(
            objectPath: Array(objectPath.dropFirst()),
            key: key,
            valueJSON: valueJSON
        )
        let property = setPropertyText(key: nextKey, valueJSON: nestedValueJSON, indent: indent)
        return setInserting(property, into: object, in: source)
    }

    private static func nestedObjectValueJSON(
        objectPath: [String],
        key: String,
        valueJSON: String
    ) -> String {
        let childIndent = "  "
        let childProperty: String
        if let nextKey = objectPath.first {
            childProperty = setPropertyText(
                key: nextKey,
                valueJSON: nestedObjectValueJSON(
                    objectPath: Array(objectPath.dropFirst()),
                    key: key,
                    valueJSON: valueJSON
                ),
                indent: childIndent
            )
        } else {
            childProperty = setPropertyText(key: key, valueJSON: valueJSON, indent: childIndent)
        }
        return "{\n\(childProperty)\n}"
    }

    private static func setPropertyIndent(for object: ObjectRange, in source: String) -> String {
        setIndentationBeforeLine(containing: object.closeBrace, in: source) + "  "
    }

    private static func setIndentationBeforeLine(containing index: String.Index, in source: String) -> String {
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

    private static func setPropertyText(key: String, valueJSON: String, indent: String) -> String {
        "\(indent)\(setQuotedJSONString(key)): \(setValueJSONForProperty(valueJSON, propertyIndent: indent))"
    }

    private static func setQuotedJSONString(_ value: String) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func setValueJSONForProperty(_ valueJSON: String, propertyIndent: String) -> String {
        let lines = valueJSON.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return valueJSON }
        return ([first] + lines.dropFirst().map { propertyIndent + $0 }).joined(separator: "\n")
    }

    private static func setInserting(_ propertyText: String, into object: ObjectRange, in source: String) -> String {
        var updated = source
        let closeOffset = source.distance(from: source.startIndex, to: object.closeBrace)
        let closingIndent = setIndentationBeforeLine(containing: object.closeBrace, in: source)
        let newline = setPreferredNewline(in: source)
        let normalizedPropertyText = setWithPreferredNewline(propertyText, newline: newline)

        if let lastProperty = object.properties.last,
           !setHasTrailingComma(after: lastProperty, before: object.closeBrace, in: source) {
            let commaOffset = source.distance(from: source.startIndex, to: lastProperty.valueEnd)
            let commaIndex = updated.index(updated.startIndex, offsetBy: commaOffset)
            updated.insert(",", at: commaIndex)
        }

        let adjustedCloseOffset = closeOffset
            + (object.properties.isEmpty || setHasTrailingComma(after: object.properties.last, before: object.closeBrace, in: source) ? 0 : 1)
        let closeIndex = updated.index(updated.startIndex, offsetBy: adjustedCloseOffset)
        updated.insert(contentsOf: "\(newline)\(normalizedPropertyText)\(newline)\(closingIndent)", at: closeIndex)
        return updated
    }

    private static func setHasTrailingComma(after property: PropertyRange?, before closeBrace: String.Index, in source: String) -> Bool {
        guard let property else { return false }
        let index = skipWhitespaceAndComments(in: source, from: property.valueEnd)
        return index < closeBrace && source[index] == ","
    }

    private static func setPreferredNewline(in source: String) -> String {
        if source.contains("\r\n") {
            return "\r\n"
        }
        if source.contains("\r") {
            return "\r"
        }
        return "\n"
    }

    private static func setWithPreferredNewline(_ text: String, newline: String) -> String {
        guard newline != "\n" else { return text }
        return text.replacingOccurrences(of: "\n", with: newline)
    }
}
