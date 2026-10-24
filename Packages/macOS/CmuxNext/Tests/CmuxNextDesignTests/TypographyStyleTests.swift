import AppKit
@testable import CmuxNextDesign
import Testing

/// The type prototype keeps font, line box and tracking decisions together.
@MainActor @Suite(.serialized) struct TypographyStyleTests {
    @Test func messageStyleUsesTheMessageFontAndAReadableLineBox() {
        let style = Typography.style(.message)
        #expect(style.font.pointSize == Typography.message.pointSize)
        #expect(style.lineHeight >= style.font.pointSize)
        #expect(style.opticalSize == style.font.pointSize)
        #expect(style.paragraphStyle.minimumLineHeight == style.lineHeight)
        #expect(style.paragraphStyle.maximumLineHeight == style.lineHeight)
    }

    @Test func semanticSpacingAliasesStayOnTheExistingGrid() {
        #expect(Metrics.inlineGap == Metrics.space2)
        #expect(Metrics.stackGap == Metrics.space3)
        #expect(Metrics.sectionGap == Metrics.space5)
        #expect(Metrics.baselineStep == 4)
    }
}
