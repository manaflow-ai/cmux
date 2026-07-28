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

    private struct Tag {
        let nameRange: Range<Int>
        let endIndex: Int
        let isClosing: Bool
        let selfClosingSlashIndex: Int?
    }

    private enum TagScan {
        case tag(Tag)
        case invalidOpener
        case unterminated
    }

    func normalize(_ data: Data) -> Data {
        let source = Array(data)
        let openingReplacement = Array(
            "<div \(hiddenTemplateAttributeName)".utf8
        )
        let closingReplacement = Array("</div".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(source.count)
        var index = 0
        var rawTextElementName: [UInt8]?

        while index < source.count {
            guard source[index] == Self.lessThan else {
                output.append(source[index])
                index += 1
                continue
            }
            let tag: Tag
            switch Self.scanTag(in: source, at: index) {
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

            if let activeRawTextElementName = rawTextElementName {
                output.append(contentsOf: source[index..<tag.endIndex])
                if tag.isClosing,
                   Self.equalsIgnoringASCIICase(
                    source,
                    range: tag.nameRange,
                    bytes: activeRawTextElementName
                   ) {
                    rawTextElementName = nil
                }
                index = tag.endIndex
                continue
            }

            if Self.equalsIgnoringASCIICase(
                source,
                range: tag.nameRange,
                bytes: Self.templateName
            ) {
                let replacement = tag.isClosing
                    ? closingReplacement
                    : openingReplacement
                output.append(contentsOf: replacement)
                Self.appendTagSuffix(
                    from: source,
                    tag: tag,
                    omittingSelfClosingSlash: !tag.isClosing,
                    to: &output
                )
            } else {
                output.append(contentsOf: source[index..<tag.endIndex])
                if !tag.isClosing {
                    rawTextElementName = Self.rawTextElementName(
                        in: source,
                        range: tag.nameRange
                    )
                }
            }
            index = tag.endIndex
        }

        return Data(output)
    }

    private static func appendTagSuffix(
        from source: [UInt8],
        tag: Tag,
        omittingSelfClosingSlash: Bool,
        to output: inout [UInt8]
    ) {
        let suffixStart = tag.nameRange.upperBound
        guard omittingSelfClosingSlash,
              let slashIndex = tag.selfClosingSlashIndex else {
            output.append(contentsOf: source[suffixStart..<tag.endIndex])
            return
        }
        output.append(contentsOf: source[suffixStart..<slashIndex])
        output.append(contentsOf: source[(slashIndex + 1)..<tag.endIndex])
    }

    private static func scanTag(
        in source: [UInt8],
        at startIndex: Int
    ) -> TagScan {
        var cursor = startIndex + 1
        guard cursor < source.count else { return .invalidOpener }

        let isClosing = source[cursor] == slash
        if isClosing {
            cursor += 1
        }
        let nameStart = cursor
        while cursor < source.count, isTagNameByte(source[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart else { return .invalidOpener }
        let nameRange = nameStart..<cursor

        var quote: UInt8?
        while cursor < source.count {
            let byte = source[cursor]
            if let activeQuote = quote {
                if byte == activeQuote {
                    quote = nil
                }
            } else if byte == singleQuote || byte == doubleQuote {
                quote = byte
            } else if byte == greaterThan {
                var lastContentIndex = cursor - 1
                while lastContentIndex >= nameRange.upperBound,
                      isASCIIWhitespace(source[lastContentIndex]) {
                    lastContentIndex -= 1
                }
                let selfClosingSlashIndex =
                    source[lastContentIndex] == slash
                        ? lastContentIndex
                        : nil
                return .tag(
                    Tag(
                        nameRange: nameRange,
                        endIndex: cursor + 1,
                        isClosing: isClosing,
                        selfClosingSlashIndex: selfClosingSlashIndex
                    )
                )
            }
            cursor += 1
        }
        return .unterminated
    }

    private static func rawTextElementName(
        in source: [UInt8],
        range: Range<Int>
    ) -> [UInt8]? {
        rawTextElementNames.first {
            equalsIgnoringASCIICase(source, range: range, bytes: $0)
        }
    }

    private static func equalsIgnoringASCIICase(
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

    private static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        (uppercaseA...uppercaseZ).contains(byte) ? byte + 32 : byte
    }

    private static func isTagNameByte(_ byte: UInt8) -> Bool {
        (lowercaseA...lowercaseZ).contains(byte)
            || (uppercaseA...uppercaseZ).contains(byte)
            || (zero...nine).contains(byte)
            || byte == hyphen
            || byte == colon
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || byte == carriageReturn
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
    private static let lessThan: UInt8 = 0x3C
    private static let greaterThan: UInt8 = 0x3E
    private static let uppercaseA: UInt8 = 0x41
    private static let uppercaseZ: UInt8 = 0x5A
    private static let lowercaseA: UInt8 = 0x61
    private static let lowercaseZ: UInt8 = 0x7A
}
