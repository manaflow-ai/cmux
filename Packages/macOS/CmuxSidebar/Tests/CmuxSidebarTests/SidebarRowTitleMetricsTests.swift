import AppKit
import SwiftUI
import Testing

@testable import CmuxSidebar

@Suite("SidebarRowTitleMetrics")
struct SidebarRowTitleMetricsTests {
    @Test("One line by default, and wrapping still shows a title in full")
    func lineLimits() {
        #expect(SidebarRowTitleMetrics(wrapsTitles: false, usesTwoLines: false).lineLimit == 1)
        #expect(SidebarRowTitleMetrics(wrapsTitles: false, usesTwoLines: true).lineLimit == 2)
        #expect(
            SidebarRowTitleMetrics(wrapsTitles: true, usesTwoLines: false).lineLimit
                == SidebarRowTitleMetrics.maxWrappedLines
        )
        // Wrapping is the stronger request, so it is not reduced to two lines.
        #expect(
            SidebarRowTitleMetrics(wrapsTitles: true, usesTwoLines: true).lineLimit
                == SidebarRowTitleMetrics.maxWrappedLines
        )
    }

    /// The AppKit cells and the SwiftUI rows resolve truncation separately, so
    /// a drift here would shorten the same title differently depending on which
    /// renderer drew the sidebar.
    @Test("Both renderers truncate a one-line title in the middle")
    func truncationModesAgree() {
        let oneLine = SidebarRowTitleMetrics(lineLimit: 1)
        #expect(oneLine.truncatesMiddle)
        #expect(oneLine.appKitLineBreakMode == .byTruncatingMiddle)
        #expect(oneLine.swiftUITruncationMode == .middle)

        for limit in [2, 3, SidebarRowTitleMetrics.maxWrappedLines] {
            let metrics = SidebarRowTitleMetrics(lineLimit: limit)
            #expect(!metrics.truncatesMiddle)
            #expect(metrics.swiftUITruncationMode == .tail)
        }
    }

    /// A bounded multi-line title has to show that it was cut; only the limit
    /// that shows a title in full may wrap without a mark.
    @Test("A two-line title truncates, a fully wrapped title does not")
    func lineBreakModesMatchTheirLimits() {
        #expect(SidebarRowTitleMetrics(lineLimit: 2).appKitLineBreakMode == .byTruncatingTail)
        #expect(
            SidebarRowTitleMetrics(lineLimit: SidebarRowTitleMetrics.maxWrappedLines).appKitLineBreakMode
                == .byWordWrapping
        )
    }

    /// A line limit is a count of lines, so the metrics cannot be built with a
    /// limit that would draw no title at all.
    @Test("A limit below one line is treated as one line")
    func limitsBelowOneLineAreClamped() {
        #expect(SidebarRowTitleMetrics(lineLimit: 0).lineLimit == 1)
        #expect(SidebarRowTitleMetrics(lineLimit: -3).truncatesMiddle)
    }

    /// Row titles are labels in a narrow column, not body text.
    @Test("The title size stays smaller than the system body size")
    func titleSizeIsSmall() {
        #expect(SidebarRowTitleMetrics.fontSize < NSFont.systemFontSize)
        #expect(SidebarRowTitleMetrics.fontSize >= 11)
    }
}
