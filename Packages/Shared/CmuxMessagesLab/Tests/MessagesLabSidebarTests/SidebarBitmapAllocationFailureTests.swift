import AppKit
import Testing
@testable import MessagesLabSidebar

/// Crash program: a sidebar bitmap that cannot be allocated used to trap on the context's
/// and the image's force unwraps; it now yields no bitmap and the caller draws nothing.
@MainActor @Suite struct SidebarBitmapAllocationFailureTests {
    @Test func anUnallocatableSidebarBitmapIsNilNotATrap() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let ctx = SidebarRenderContext(metrics: SidebarMetrics(width: 320), palette: SidebarPalette.resolve(appearance), scale: 2,
                                       space: CGColorSpaceCreateDeviceRGB(), generation: 0, bellSecondary: nil, bellSelected: nil,
                                       now: Date())
        let image = SidebarDraw.bitmap(size: CGSize(width: 1e9, height: 1e9), ctx: ctx) { _ in }
        #expect(image == nil)
    }
}
