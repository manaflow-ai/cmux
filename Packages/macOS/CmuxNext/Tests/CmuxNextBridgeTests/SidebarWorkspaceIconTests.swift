import CmuxNextDesign
import CmuxNextSidebar
import Testing
@testable import CmuxNextBridge

/// A workspace with both a color and an icon shows both (R94, coordinator):
/// a symbol tinted with the color, an emoji on a chip of the color. A color
/// alone is the swatch dot; an unknown icon string shows nothing.
struct SidebarWorkspaceIconTests {
    @Test func iconAndColorShowTogether() {
        #expect(SidebarMapping.icon(color: "green", icon: "🚀") == .emoji("🚀", chip: .green))
        #expect(SidebarMapping.icon(color: "green", icon: "house") == .symbol("house", tint: .green))
        #expect(SidebarMapping.icon(color: "green", icon: nil) == .swatch(.green))
        #expect(SidebarMapping.icon(color: nil, icon: "🚀") == .emoji("🚀"))
        #expect(SidebarMapping.icon(color: nil, icon: "house") == .symbol("house"))
        #expect(SidebarMapping.icon(color: nil, icon: "not an icon") == nil)
        #expect(SidebarMapping.icon(color: nil, icon: nil) == nil)
    }
}
