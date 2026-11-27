import Foundation

/// Preserves HTML5 template ownership across Foundation's HTML4 tidy parser.
///
/// The libxml HTML parser used by ``XMLDocument`` discards `<template>` tags
/// and promotes their hidden descendants into the visible body. This normalizer
/// rewrites only actual template tags into uniquely marked, nestable `<div>`
/// elements before DOM construction. Raw-text element contents remain byte-for-
/// byte unchanged.
struct HTMLFoundationCompatibilityNormalizer: Sendable {
    let hiddenTemplateAttributeName: String

    private static let templateName = Array("template".utf8)
    private static let rawTextElementNames = [
        "iframe",
        "noembed",
        "noframes",
        "plaintext",
        "script",
        "style",
        "textarea",
        "title",
        "xmp",
    ].map { Array($0.utf8) }

    func normalize(_ data: Data) -> Data {
        let source = Array(data)
        let openingReplacement = Array(
            "<div \(hiddenTemplateAttributeName)".utf8
        )
        let closingReplacement = Array("</div".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        let lastRawTextClosingIndices = lastRawTextClosingTagIndices(
            in: source
        )
        var index = 0
        var rawTextElementIndex: Int?

        while index < source.count {
            guard source[index] == Self.lessThan else {
                output.append(source[index])
                index += 1
                continue
            }
            if let activeRawTextElementIndex = rawTextElementIndex {
                guard let closingTag = scanRawTextClosingTag(
                    in: source,
                    at: index,
                    name: Self.rawTextElementNames[
                        activeRawTextElementIndex
                    ]
                ) else {
                    output.append(source[index])
                    index += 1
                    continue
                }
                output.append(contentsOf: source[index..<closingTag.endIndex])
                rawTextElementIndex = nil
                index = closingTag.endIndex
                continue
            }
            let tag: HTMLFoundationCompatibilityTag
            switch scanTag(in: source, at: index) {
            case .tag(let scannedTag):
                tag = scannedTag
            case .invalidOpener:
                output.append(source[index])
                index += 1
                continue
            case .unterminated:
                output.append(contentsOf: source[index...])
                index = source.count
                continue
            }

            if equalsIgnoringASCIICase(
                source,
                range: tag.nameRange,
                bytes: Self.templateName
            ) {
                let replacement = tag.isClosing
                    ? closingReplacement
                    : openingReplacement
                output.append(contentsOf: replacement)
                appendTagSuffix(
                    from: source,
                    tag: tag,
                    omittingSelfClosingSlash: !tag.isClosing,
                    to: &output
                )
                if !tag.isClosing, tag.selfClosingSlashIndex != nil {
                    output.append(contentsOf: closingReplacement)
                    output.append(Self.greaterThan)
                }
            } else {
                let matchedRawTextElementIndex = tag.isClosing
                    ? nil
                    : matchingRawTextElementIndex(
                        in: source,
                        range: tag.nameRange
                    )
                if let matchedRawTextElementIndex,
                   let slashIndex = tag.selfClosingSlashIndex,
                   let closingIndex = lastRawTextClosingIndices[
                       matchedRawTextElementIndex
                   ],
                   closingIndex >= tag.endIndex {
                    output.append(contentsOf: source[index..<slashIndex])
                    output.append(
                        contentsOf: source[(slashIndex + 1)..<tag.endIndex]
                    )
                    rawTextElementIndex = matchedRawTextElementIndex
                } else {
                    output.append(contentsOf: source[index..<tag.endIndex])
                    if tag.selfClosingSlashIndex == nil {
                        rawTextElementIndex = matchedRawTextElementIndex
                    }
                }
            }
            index = tag.endIndex
        }

        return Data(output)
    }

    private func appendTagSuffix(
        from source: [UInt8],
        tag: HTMLFoundationCompatibilityTag,
        omittingSelfClosingSlash: Bool,
        to output: inout [UInt8]
    ) {
        let suffixStart = tag.nameRange.upperBound
        if omittingSelfClosingSlash,
           let slashIndex = tag.selfClosingSlashIndex {
            output.append(contentsOf: source[suffixStart..<slashIndex])
            output.append(contentsOf: source[(slashIndex + 1)..<tag.endIndex])
            return
        }
        guard omittingSelfClosingSlash,
              source[tag.endIndex - 2] == Self.slash else {
            output.append(contentsOf: source[suffixStart..<tag.endIndex])
            return
        }
        // libxml treats the final byte of an unquoted attribute value as an
        // XML-style closing slash. Separate it from `>` after rewriting.
        output.append(contentsOf: source[suffixStart..<(tag.endIndex - 1)])
        output.append(Self.space)
        output.append(Self.greaterThan)
    }

    private func scanTag(
        in source: [UInt8],
        at startIndex: Int
    ) -> HTMLFoundationCompatibilityTagScan {
        var cursor = startIndex + 1
        guard cursor < source.count else { return .invalidOpener }

        let isClosing = source[cursor] == Self.slash
        if isClosing {
            cursor += 1
        }
        let nameStart = cursor
        while cursor < source.count, isTagNameByte(source[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart else { return .invalidOpener }
        let nameRange = nameStart..<cursor

        var state = HTMLFoundationCompatibilityTokenizerState
            .beforeAttributeName
        while cursor < source.count {
            let byte = source[cursor]
            switch state {
            case .beforeAttributeName,
                 .attributeName,
                 .afterAttributeName,
                 .afterQuotedAttributeValue:
                if byte == Self.greaterThan {
                    return scannedTag(
                        nameRange: nameRange,
                        endIndex: cursor + 1,
                        isClosing: isClosing
                    )
                }
                if isSelfClosingSequence(in: source, at: cursor) {
                    return scannedTag(
                        nameRange: nameRange,
                        endIndex: cursor + 2,
                        isClosing: isClosing,
                        selfClosingSlashIndex: cursor
                    )
                }
            case .beforeAttributeValue:
                if byte == Self.greaterThan {
                    return scannedTag(
                        nameRange: nameRange,
                        endIndex: cursor + 1,
                        isClosing: isClosing
                    )
                }
            case .doubleQuotedAttributeValue,
                 .singleQuotedAttributeValue,
                 .unquotedAttributeValue:
                break
            }
            switch state {
            case .beforeAttributeName:
                if isASCIIWhitespace(byte) {
                    cursor += 1
                    continue
                }
                state = .attributeName
                cursor += 1
            case .attributeName:
                if isASCIIWhitespace(byte) {
                    state = .afterAttributeName
                    cursor += 1
                } else if byte == Self.equals {
                    state = .beforeAttributeValue
                    cursor += 1
                } else {
                    cursor += 1
                }
            case .afterAttributeName:
                if isASCIIWhitespace(byte) {
                    cursor += 1
                } else if byte == Self.equals {
                    state = .beforeAttributeValue
                    cursor += 1
                } else {
                    state = .attributeName
                    cursor += 1
                }
            case .beforeAttributeValue:
                if isASCIIWhitespace(byte) {
                    cursor += 1
                } else if byte == Self.doubleQuote {
                    state = .doubleQuotedAttributeValue
                    cursor += 1
                } else if byte == Self.singleQuote {
                    state = .singleQuotedAttributeValue
                    cursor += 1
                } else {
                    // Solidus is valid data here and throughout an unquoted
                    // value. It is syntactic only after an attribute boundary.
                    state = .unquotedAttributeValue
                    cursor += 1
                }
            case .doubleQuotedAttributeValue:
                if byte == Self.doubleQuote {
                    state = .afterQuotedAttributeValue
                }
                cursor += 1
            case .singleQuotedAttributeValue:
                if byte == Self.singleQuote {
                    state = .afterQuotedAttributeValue
                }
                cursor += 1
            case .unquotedAttributeValue:
                if isASCIIWhitespace(byte) {
                    state = .beforeAttributeName
                    cursor += 1
                } else if byte == Self.greaterThan {
                    return scannedTag(
                        nameRange: nameRange,
                        endIndex: cursor + 1,
                        isClosing: isClosing
                    )
                } else {
                    cursor += 1
                }
            case .afterQuotedAttributeValue:
                if isASCIIWhitespace(byte) {
                    state = .beforeAttributeName
                    cursor += 1
                } else {
                    state = .beforeAttributeName
                }
            }
        }
        return .unterminated
    }

    private func scannedTag(
        nameRange: Range<Int>,
        endIndex: Int,
        isClosing: Bool,
        selfClosingSlashIndex: Int? = nil
    ) -> HTMLFoundationCompatibilityTagScan {
        .tag(
            HTMLFoundationCompatibilityTag(
                nameRange: nameRange,
                endIndex: endIndex,
                isClosing: isClosing,
                selfClosingSlashIndex: selfClosingSlashIndex
            )
        )
    }

    private func isSelfClosingSequence(
        in source: [UInt8],
        at index: Int
    ) -> Bool {
        source[index] == Self.slash
            && index + 1 < source.count
            && source[index + 1] == Self.greaterThan
    }

    private func scanRawTextClosingTag(
        in source: [UInt8],
        at startIndex: Int,
        name: [UInt8]
    ) -> HTMLFoundationCompatibilityTag? {
        let nameStart = startIndex + 2
        let nameEnd = nameStart + name.count
        guard startIndex + 1 < source.count,
              source[startIndex + 1] == Self.slash,
              nameEnd < source.count,
              equalsIgnoringASCIICase(
                source,
                range: nameStart..<nameEnd,
                bytes: name
              ) else {
            return nil
        }

        var cursor = nameEnd
        while cursor < source.count, isASCIIWhitespace(source[cursor]) {
            cursor += 1
        }
        if cursor < source.count, source[cursor] == Self.slash {
            cursor += 1
            while cursor < source.count, isASCIIWhitespace(source[cursor]) {
                cursor += 1
            }
        }
        guard cursor < source.count,
              source[cursor] == Self.greaterThan else {
            return nil
        }
        return HTMLFoundationCompatibilityTag(
            nameRange: nameStart..<nameEnd,
            endIndex: cursor + 1,
            isClosing: true,
            selfClosingSlashIndex: nil
        )
    }

    /// Finds the final lexical closing tag for every bounded raw-text name.
    private func lastRawTextClosingTagIndices(
        in source: [UInt8]
    ) -> [Int?] {
        var result = [Int?](
            repeating: nil,
            count: Self.rawTextElementNames.count
        )
        var index = 0
        while index < source.count {
            guard source[index] == Self.lessThan else {
                index += 1
                continue
            }
            var matchedEndIndex: Int?
            for (elementIndex, name) in Self.rawTextElementNames.enumerated() {
                guard let tag = scanRawTextClosingTag(
                    in: source,
                    at: index,
                    name: name
                ) else {
                    continue
                }
                result[elementIndex] = index
                matchedEndIndex = tag.endIndex
                break
            }
            index = matchedEndIndex ?? (index + 1)
        }
        return result
    }

    private func matchingRawTextElementIndex(
        in source: [UInt8],
        range: Range<Int>
    ) -> Int? {
        Self.rawTextElementNames.firstIndex {
            equalsIgnoringASCIICase(source, range: range, bytes: $0)
        }
    }

    private func equalsIgnoringASCIICase(
        _ source: [UInt8],
        range: Range<Int>,
        bytes: [UInt8]
    ) -> Bool {
        guard range.count == bytes.count else { return false }
        for (sourceIndex, expected) in zip(range, bytes) {
            guard lowercaseASCII(source[sourceIndex]) == expected else {
                return false
            }
        }
        return true
    }

    private func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        (Self.uppercaseA...Self.uppercaseZ).contains(byte) ? byte + 32 : byte
    }

    private func isTagNameByte(_ byte: UInt8) -> Bool {
        (Self.lowercaseA...Self.lowercaseZ).contains(byte)
            || (Self.uppercaseA...Self.uppercaseZ).contains(byte)
            || (Self.zero...Self.nine).contains(byte)
            || byte == Self.hyphen
            || byte == Self.colon
    }

    private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == Self.space
            || byte == Self.tab
            || byte == Self.lineFeed
            || byte == Self.carriageReturn
    }

    private static let tab: UInt8 = 0x09
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let space: UInt8 = 0x20
    private static let doubleQuote: UInt8 = 0x22
    private static let singleQuote: UInt8 = 0x27
    private static let hyphen: UInt8 = 0x2D
    private static let slash: UInt8 = 0x2F
    private static let zero: UInt8 = 0x30
    private static let nine: UInt8 = 0x39
    private static let colon: UInt8 = 0x3A
    private static let equals: UInt8 = 0x3D
    private static let lessThan: UInt8 = 0x3C
    private static let greaterThan: UInt8 = 0x3E
    private static let uppercaseA: UInt8 = 0x41
    private static let uppercaseZ: UInt8 = 0x5A
    private static let lowercaseA: UInt8 = 0x61
    private static let lowercaseZ: UInt8 = 0x7A
}
