@testable import CmuxNextBrowser
import Testing

/// A live-resize gap in a Chromium page takes the document's own background
/// (`CEFTab+ResizeBackdrop`): the page script's `[r, g, b]` reply becomes the
/// opaque color Chromium and the host view paint, and anything else is no color.
@Suite struct CEFResizeBackdropTests {
    @Test func rgbReplyBecomesOpaqueARGB() {
        #expect(CEFTab.backdropARGB(from: .array([.number(11), .number(93), .number(59)])) == 0xFF0B_5D3B)
        #expect(CEFTab.backdropARGB(from: .array([.number(255), .number(255), .number(255)])) == 0xFFFF_FFFF)
    }

    @Test func outOfRangeChannelsClamp() {
        #expect(CEFTab.backdropARGB(from: .array([.number(-4), .number(300), .number(127.6)])) == 0xFF00_FF80)
    }

    @Test func otherRepliesAreNoColor() {
        #expect(CEFTab.backdropARGB(from: .null) == nil)
        #expect(CEFTab.backdropARGB(from: .string("rgb(0, 0, 0)")) == nil)
        #expect(CEFTab.backdropARGB(from: .array([.number(1), .number(2)])) == nil)
        #expect(CEFTab.backdropARGB(from: .array([.number(1), .string("2"), .number(3)])) == nil)
        #expect(CEFTab.backdropARGB(from: .array([.number(1), .number(.nan), .number(3)])) == nil)
    }
}
