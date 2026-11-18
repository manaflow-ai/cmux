import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A long workspace title ("Make the hover cards look like Codex's") read as cut off in the
/// sidebar: the title has no ellipsis by design (fe1c0f8) and fades its tail instead, and the
/// 16 pt fade ended right at a word gap, so at 1x it looked like a hard cut. The fade is 24 pt
/// at Default (`space6 + space4`), scaled to 21.5 pt at Compact.
@MainActor @Suite struct SidebarTitleFadeWidthTests {
    @Test func aClippedTitleFadeScalesWithCompact() {
        DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            #expect(SidebarStyle.titleFadeWidth == Metrics.scale(21.5))
        }
    }
}
