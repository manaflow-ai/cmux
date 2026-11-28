@testable import CmuxTabsKit
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Testing

/// Leo's screenshot (2026-11-22): card titles were legible behind the grid's header, because the
/// edge faded from its middle. The edge must stay opaque down to the controls' bottom.
struct OverviewTitleEdgeTests {
    @Test func defaultIsOpaqueBehindTheWholeHeader() {
        let edge = OverviewTitleEdge(style: .opaqueThenFade, safeTop: 62, control: 48)
        // Controls: 4 pt under the safe area, 48 tall; the header's two text lines end inside.
        #expect(edge.opaqueBottom == 114)
        // Clear exactly where the first row starts (OverviewLayout.pinnedTop).
        let layout = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 4)
        #expect(edge.height == layout.pinnedTop)
        // The old mask was opaque only to half its height: 61 of 122 pt, mid-title.
        #expect(edge.opaqueStop > 0.9)
    }

    @Test func galleryVariants() {
        let hard = OverviewTitleEdge(style: .hard, safeTop: 62, control: 48)
        #expect(hard.opaqueBottom == hard.height && hard.opaqueStop == 1)
        let blur = OverviewTitleEdge(style: .progressiveBlur, safeTop: 62, control: 48)
        #expect(blur.opaqueBottom == 114 && blur.height == 150)
    }

    @Test func releaseAndUnknownValuesDrawTheDefault() {
        #expect(OverviewTitleEdgeStyle.current(environment: [:]) == .opaqueThenFade)
        #expect(OverviewTitleEdgeStyle.current(environment: ["CMUX_TABS_TITLE_EDGE": "nope"]) == .opaqueThenFade)
    }
}
