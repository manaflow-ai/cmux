@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

struct LaunchPolishVisibilityTests {
    @Test func appStoreStaysInStoredLayoutButIsFilteredWhenPreviewFeaturesAreOff() {
        let stored = SidebarLayoutDocument.defaults
        let hidden = SidebarRows.visibleLayout(stored, showAppStore: false)
        #expect(stored.firstItem(with: .app("cmux/app-store")) != nil)
        #expect(hidden.firstItem(with: .app("cmux/app-store")) == nil)
        #expect(SidebarRows.visibleLayout(stored, showAppStore: true) == stored.withoutChats)
    }
}
