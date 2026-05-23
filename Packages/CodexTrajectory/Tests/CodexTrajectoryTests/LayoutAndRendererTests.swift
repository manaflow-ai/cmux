import CoreGraphics
import XCTest
@testable import CodexTrajectory

final class LayoutAndRendererTests: XCTestCase {
    func testLayoutPaginatesLargeCommandOutput() {
        let text = (0..<12_000)
            .map { "line \($0): abcdefghijklmnopqrstuvwxyz" }
            .joined(separator: "\n")
        let block = CodexTrajectoryBlock(
            id: "command-output",
            kind: .commandOutput,
            title: "stdout",
            text: text
        )

        let layout = CodexTrajectoryLayoutEngine().layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(
                width: 640,
                pageLineLimit: 250,
                maximumPageCharacters: 20_000
            ),
            theme: .defaultLight()
        )

        XCTAssertGreaterThan(layout.pages.count, 30)
        XCTAssertGreaterThan(layout.totalHeight, 10_000)
        XCTAssertEqual(layout.pages.first?.textRange.location, 0)
        XCTAssertEqual(layout.pages.last?.textRange.upperBound, (block.displayText as NSString).length)
        XCTAssertTrue(layout.pages.allSatisfy { $0.measuredSize.width == 640 })
    }

    func testLayoutSplitsAfterPageLineLimitIsExceeded() {
        let block = CodexTrajectoryBlock(
            id: "lines",
            kind: .commandOutput,
            text: "one\ntwo\nthree"
        )

        let layout = CodexTrajectoryLayoutEngine().layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(
                width: 320,
                pageLineLimit: 2,
                maximumPageCharacters: 10_000
            ),
            theme: .defaultLight()
        )

        XCTAssertEqual(layout.pages.count, 2)
    }

    func testLayoutSplitsPageCharacterLimitByUTF16Units() {
        let text = String(repeating: "😀", count: 3)
        let block = CodexTrajectoryBlock(
            id: "emoji",
            kind: .commandOutput,
            text: text
        )

        let layout = CodexTrajectoryLayoutEngine().layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(
                width: 320,
                pageLineLimit: 100,
                maximumPageCharacters: 4
            ),
            theme: .defaultLight()
        )

        XCTAssertEqual(layout.pages.map(\.textRange.length), [4, 2])
        XCTAssertEqual(layout.pages.last?.textRange.upperBound, (text as NSString).length)
    }

    func testLayoutUsesRenderedMarkdownTextForAssistantBlocks() throws {
        let theme = CodexTrajectoryTheme.defaultLight(textSize: 14, monospacedSize: 11)
        let block = CodexTrajectoryBlock(
            id: "assistant",
            kind: .assistantText,
            text: "## Heading\n\nThis is **bold** with `code` and [link](https://example.com)."
        )

        let rendered = codexTrajectoryRenderedText(for: block, theme: theme)
        let layout = CodexTrajectoryLayoutEngine().layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(width: 300),
            theme: theme
        )

        XCTAssertTrue(rendered.plainText.contains("Heading"))
        XCTAssertFalse(rendered.plainText.contains("**"))
        XCTAssertFalse(rendered.plainText.contains("`code`"))
        XCTAssertEqual(layout.pages.last?.textRange.upperBound, (rendered.plainText as NSString).length)
        let firstPage = try XCTUnwrap(layout.pages.first)
        let page = codexTrajectoryRenderedPage(for: block, page: firstPage, theme: theme)
        XCTAssertGreaterThan(CFAttributedStringGetLength(page.attributedString), 0)
    }

    func testDefaultThemeKeepsUserMarkdownLiteral() {
        let theme = CodexTrajectoryTheme.defaultLight(textSize: 14, monospacedSize: 11)
        let block = CodexTrajectoryBlock(
            id: "user",
            kind: .userText,
            text: "Use **literal** `markdown`."
        )

        let rendered = codexTrajectoryRenderedText(for: block, theme: theme)

        XCTAssertEqual(rendered.plainText, "Use **literal** `markdown`.")
    }

    func testLayoutUsesSeparateStylesForBodyAndCommandBlocks() {
        let theme = CodexTrajectoryTheme.defaultLight(textSize: 14, monospacedSize: 11)
        let engine = CodexTrajectoryLayoutEngine()
        let assistant = engine.layout(
            block: CodexTrajectoryBlock(id: "a", kind: .assistantText, text: "hello"),
            configuration: CodexTrajectoryLayoutConfiguration(width: 300),
            theme: theme
        )
        let command = engine.layout(
            block: CodexTrajectoryBlock(id: "c", kind: .commandOutput, text: "hello"),
            configuration: CodexTrajectoryLayoutConfiguration(width: 300),
            theme: theme
        )

        XCTAssertNotEqual(assistant.totalHeight, 0)
        XCTAssertNotEqual(command.totalHeight, 0)
        XCTAssertNotNil(theme.style(for: .commandOutput).backgroundColor)
    }

    func testRendererDrawsIntoBitmapContext() throws {
        let theme = CodexTrajectoryTheme.defaultLight()
        let block = CodexTrajectoryBlock(id: "a", kind: .commandOutput, title: "stdout", text: "hello")
        let layout = CodexTrajectoryLayoutEngine().layout(
            block: block,
            configuration: CodexTrajectoryLayoutConfiguration(width: 240),
            theme: theme
        )
        let page = try XCTUnwrap(layout.pages.first)

        let width = 240
        let height = Int(ceil(page.measuredSize.height))
        var pixels = Array(repeating: UInt8(0), count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            CodexTrajectoryRenderer().draw(
                block: block,
                page: page,
                in: context,
                rect: CGRect(x: 0, y: 0, width: width, height: height),
                theme: theme,
                coordinates: .yDown
            )
            return true
        }

        XCTAssertTrue(drew)
        XCTAssertTrue(pixels.contains { $0 != 0 })
    }
}
