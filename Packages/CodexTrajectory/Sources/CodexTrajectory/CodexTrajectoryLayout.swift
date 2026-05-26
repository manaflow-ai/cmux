import CoreGraphics
import CoreText
import CMUXMarkdown
import CryptoKit
import Foundation

public struct CodexTrajectoryTextRange: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public var upperBound: Int {
        location + length
    }
}

public struct CodexTrajectoryLayoutConfiguration: Hashable, Sendable {
    public var width: CGFloat
    public var pageLineLimit: Int
    public var maximumPageCharacters: Int

    public init(
        width: CGFloat,
        pageLineLimit: Int = 240,
        maximumPageCharacters: Int = 16_384
    ) {
        self.width = max(1, width)
        self.pageLineLimit = max(1, pageLineLimit)
        self.maximumPageCharacters = max(1, maximumPageCharacters)
    }
}

public struct CodexTrajectoryLayoutPage: Hashable {
    public var blockID: String
    public var blockKind: CodexTrajectoryBlockKind
    public var pageIndex: Int
    public var textRange: CodexTrajectoryTextRange
    public var measuredSize: CGSize
    public var lineCount: Int

    public init(
        blockID: String,
        blockKind: CodexTrajectoryBlockKind,
        pageIndex: Int,
        textRange: CodexTrajectoryTextRange,
        measuredSize: CGSize,
        lineCount: Int
    ) {
        self.blockID = blockID
        self.blockKind = blockKind
        self.pageIndex = pageIndex
        self.textRange = textRange
        self.measuredSize = measuredSize
        self.lineCount = lineCount
    }
}

public struct CodexTrajectoryBlockLayout: Hashable {
    public var blockID: String
    public var pages: [CodexTrajectoryLayoutPage]
    public var totalHeight: CGFloat

    public init(blockID: String, pages: [CodexTrajectoryLayoutPage]) {
        self.blockID = blockID
        self.pages = pages
        self.totalHeight = pages.reduce(0) { $0 + $1.measuredSize.height }
    }
}

public struct CodexTrajectoryRenderedText {
    public var plainText: String
    public var attributedString: CFAttributedString

    public init(plainText: String, attributedString: CFAttributedString) {
        self.plainText = plainText
        self.attributedString = attributedString
    }
}

private final class CodexTrajectoryRenderedTextBox: NSObject {
    let value: CodexTrajectoryRenderedText

    init(_ value: CodexTrajectoryRenderedText) {
        self.value = value
    }
}

private final class CodexTrajectoryRenderedTextCache: @unchecked Sendable {
    private let cache: NSCache<NSString, CodexTrajectoryRenderedTextBox>

    init() {
        let cache = NSCache<NSString, CodexTrajectoryRenderedTextBox>()
        cache.countLimit = 2_048
        cache.totalCostLimit = 96 * 1024 * 1024
        self.cache = cache
    }

    func value(for key: String) -> CodexTrajectoryRenderedText? {
        cache.object(forKey: key as NSString)?.value
    }

    func insert(_ value: CodexTrajectoryRenderedText, for key: String, cost: Int) {
        cache.setObject(
            CodexTrajectoryRenderedTextBox(value),
            forKey: key as NSString,
            cost: cost
        )
    }
}

private let codexTrajectoryRenderedTextCache = CodexTrajectoryRenderedTextCache()

public struct CodexTrajectoryLayoutEngine {
    public init() {}

    public func layout(
        block: CodexTrajectoryBlock,
        configuration: CodexTrajectoryLayoutConfiguration,
        theme: CodexTrajectoryTheme
    ) -> CodexTrajectoryBlockLayout {
        let rendered = codexTrajectoryRenderedText(for: block, theme: theme)
        let displayText = rendered.plainText.isEmpty ? " " : rendered.plainText
        let ranges = pageRanges(
            in: displayText,
            pageLineLimit: configuration.pageLineLimit,
            maximumPageCharacters: configuration.maximumPageCharacters
        )
        let insets = theme.contentInsets(for: block.kind)
        let textWidth = max(1, configuration.width - insets.left - insets.right)

        let pages = ranges.enumerated().map { pageIndex, range in
            let text = displayText.codexTrajectorySubstring(in: range)
            let attributed = attributedSubstring(rendered.attributedString, in: range)
            let measured = measure(
                attributed: attributed,
                fallbackStyle: theme.style(for: block.kind),
                width: textWidth,
                insets: insets
            )
            return CodexTrajectoryLayoutPage(
                blockID: block.id,
                blockKind: block.kind,
                pageIndex: pageIndex,
                textRange: range,
                measuredSize: measured,
                lineCount: max(1, text.filter { $0 == "\n" }.count + 1)
            )
        }

        return CodexTrajectoryBlockLayout(blockID: block.id, pages: pages)
    }

    private func measure(
        attributed: CFAttributedString,
        fallbackStyle: CodexTrajectoryBlockStyle,
        width: CGFloat,
        insets: CodexTrajectoryInsets
    ) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        let lineHeight = ceil(
            CTFontGetAscent(fallbackStyle.font) +
                CTFontGetDescent(fallbackStyle.font) +
                CTFontGetLeading(fallbackStyle.font)
        )
        return CGSize(
            width: width + insets.left + insets.right,
            height: max(lineHeight, ceil(suggested.height)) + insets.top + insets.bottom
        )
    }

    private func pageRanges(
        in text: String,
        pageLineLimit: Int,
        maximumPageCharacters: Int
    ) -> [CodexTrajectoryTextRange] {
        guard !text.isEmpty else {
            return [CodexTrajectoryTextRange(location: 0, length: 0)]
        }

        var ranges: [CodexTrajectoryTextRange] = []
        var start = 0
        var current = 0
        var lines = 1
        var pageUTF16Units = 0
        let resolvedPageLineLimit = max(1, pageLineLimit)
        let resolvedMaximumPageCharacters = max(1, maximumPageCharacters)

        for character in text {
            let characterUTF16Units = character.utf16.count
            current += characterUTF16Units
            pageUTF16Units += characterUTF16Units
            if character == "\n" {
                lines += 1
            }

            if lines > resolvedPageLineLimit || pageUTF16Units >= resolvedMaximumPageCharacters {
                ranges.append(CodexTrajectoryTextRange(location: start, length: current - start))
                start = current
                lines = 1
                pageUTF16Units = 0
            }
        }

        if start < current {
            ranges.append(CodexTrajectoryTextRange(location: start, length: current - start))
        }

        return ranges
    }
}

public func codexTrajectoryRenderedText(
    for block: CodexTrajectoryBlock,
    theme: CodexTrajectoryTheme
) -> CodexTrajectoryRenderedText {
    let displayText = block.displayText.isEmpty ? " " : block.displayText
    let cacheKey = [
        theme.identifier,
        block.kind.rawValue,
        block.id,
        codexTrajectoryContentDigest(block.title),
        codexTrajectoryContentDigest(block.text),
        "\(displayText.utf16.count)",
    ].joined(separator: "\u{1f}")
    if let cached = codexTrajectoryRenderedTextCache.value(for: cacheKey) {
        return cached
    }

    let value: CodexTrajectoryRenderedText
    guard let markdownTheme = theme.markdownTheme(for: block.kind) else {
        value = CodexTrajectoryRenderedText(
            plainText: displayText,
            attributedString: makeAttributedString(text: displayText, style: theme.style(for: block.kind))
        )
        codexTrajectoryRenderedTextCache.insert(value, for: cacheKey, cost: max(1, displayText.utf16.count * 2))
        return value
    }

    let rendered = CMUXMarkdownCoreTextRenderer(theme: markdownTheme).render(displayText)
    value = CodexTrajectoryRenderedText(
        plainText: rendered.plainText,
        attributedString: rendered.attributedString
    )
    codexTrajectoryRenderedTextCache.insert(value, for: cacheKey, cost: max(1, rendered.plainText.utf16.count * 4))
    return value
}

private func codexTrajectoryContentDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

public func codexTrajectoryRenderedPage(
    for block: CodexTrajectoryBlock,
    page: CodexTrajectoryLayoutPage,
    theme: CodexTrajectoryTheme
) -> CodexTrajectoryRenderedText {
    let rendered = codexTrajectoryRenderedText(for: block, theme: theme)
    return CodexTrajectoryRenderedText(
        plainText: rendered.plainText.codexTrajectorySubstring(in: page.textRange),
        attributedString: attributedSubstring(rendered.attributedString, in: page.textRange)
    )
}

func makeAttributedString(text: String, style: CodexTrajectoryBlockStyle) -> CFAttributedString {
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: style.font,
        kCTForegroundColorAttributeName: style.foregroundColor,
    ]
    return CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary)
}

func attributedSubstring(_ attributed: CFAttributedString, in range: CodexTrajectoryTextRange) -> CFAttributedString {
    let length = CFAttributedStringGetLength(attributed)
    let location = min(max(0, range.location), length)
    let upper = min(max(location, range.upperBound), length)
    guard upper > location,
          let substring = CFAttributedStringCreateWithSubstring(
            kCFAllocatorDefault,
            attributed,
            CFRange(location: location, length: upper - location)
          ) else {
        return CFAttributedStringCreate(kCFAllocatorDefault, " " as CFString, [:] as CFDictionary)
    }
    return substring
}

extension String {
    func codexTrajectorySubstring(in range: CodexTrajectoryTextRange) -> String {
        guard range.length > 0 else { return "" }
        let utf16View = utf16
        guard let lowerUTF16 = utf16View.index(
            utf16View.startIndex,
            offsetBy: range.location,
            limitedBy: utf16View.endIndex
        ),
            let upperUTF16 = utf16View.index(
                lowerUTF16,
                offsetBy: range.length,
                limitedBy: utf16View.endIndex
            ),
            let lower = String.Index(lowerUTF16, within: self),
            let upper = String.Index(upperUTF16, within: self) else {
            return ""
        }
        return String(self[lower..<upper])
    }
}
