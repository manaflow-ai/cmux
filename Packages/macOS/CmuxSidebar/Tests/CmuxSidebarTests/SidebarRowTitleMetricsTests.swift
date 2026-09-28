import AppKit
import SwiftUI
import Testing

@testable import CmuxSidebar

@Suite("SidebarRowTitleMetrics")
struct SidebarRowTitleMetricsTests {
    @Test("One line by default, and wrapping still shows a title in full")
    func lineLimits() {
        #expect(SidebarRowTitleMetrics.lineLimit(wrapsTitles: false, usesTwoLines: false) == 1)
        #expect(SidebarRowTitleMetrics.lineLimit(wrapsTitles: false, usesTwoLines: true) == 2)
        #expect(
            SidebarRowTitleMetrics.lineLimit(wrapsTitles: true, usesTwoLines: false)
                == SidebarRowTitleMetrics.maxWrappedLines
        )
        // Wrapping is the stronger request, so it is not reduced to two lines.
        #expect(
            SidebarRowTitleMetrics.lineLimit(wrapsTitles: true, usesTwoLines: true)
                == SidebarRowTitleMetrics.maxWrappedLines
        )
    }

    /// The AppKit cells and the SwiftUI rows resolve truncation separately, so
    /// a drift here would shorten the same title differently depending on which
    /// renderer drew the sidebar.
    @Test("Both renderers truncate a one-line title in the middle")
    func truncationModesAgree() {
        #expect(SidebarRowTitleMetrics.appKitLineBreakMode(lineLimit: 1) == .byTruncatingMiddle)
        #expect(SidebarRowTitleMetrics.swiftUITruncationMode(lineLimit: 1) == .middle)

        for limit in [2, 3, SidebarRowTitleMetrics.maxWrappedLines] {
            #expect(!SidebarRowTitleMetrics.truncatesMiddle(lineLimit: limit))
            #expect(SidebarRowTitleMetrics.swiftUITruncationMode(lineLimit: limit) == .tail)
        }
    }

    /// A bounded multi-line title has to show that it was cut; only the limit
    /// that shows a title in full may wrap without a mark.
    @Test("A two-line title truncates, a fully wrapped title does not")
    func lineBreakModesMatchTheirLimits() {
        #expect(SidebarRowTitleMetrics.appKitLineBreakMode(lineLimit: 2) == .byTruncatingTail)
        #expect(
            SidebarRowTitleMetrics.appKitLineBreakMode(lineLimit: SidebarRowTitleMetrics.maxWrappedLines)
                == .byWordWrapping
        )
    }

    /// Row titles are labels in a narrow column, not body text.
    @Test("The title size stays smaller than the system body size")
    func titleSizeIsSmall() {
        #expect(SidebarRowTitleMetrics.fontSize < NSFont.systemFontSize)
        #expect(SidebarRowTitleMetrics.fontSize >= 11)
    }
}
