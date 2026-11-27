import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A long workspace title ("Make the hover cards look like Codex's") read as cut off in the
/// sidebar: the title has no ellipsis by design (fe1c0f8) and fades its tail instead, and the
/// 16 pt fade ended right at a word gap, so at 1x it looked like a hard cut. The fade is 24 pt
/// at Compact (`space6 + space4`), long enough to read as a fade.
@MainActor @Suite struct SidebarTitleFadeWidthTests {
    @Test func aClippedTitleFadesOver24PointsAtCompact() {
        DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            #expect(SidebarStyle.titleFadeWidth == Metrics.scale(24))
        }
    }
}
