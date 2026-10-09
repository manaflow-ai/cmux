import AppKit
import Testing
@testable import CmuxNextSidebar

/// The sidebar's helpers keep an unowned back-reference to their view
/// (crash-allowlist.json: "owned child, nested lifetime"); they end with it.
@MainActor @Suite struct SidebarChildLifetimeTests {
    @Test func autoscrollAndSpacePagingEndWithTheirViews() {
        weak var weakSidebar: SidebarView?
        weak var weakList: SidebarListView?
        weak var weakAutoscroll: SidebarDragAutoscroll?
        weak var weakPaging: SidebarSpacePaging?
        // AppKit autoreleases views: the pool ends with the scope.
        autoreleasepool {
            let sidebar = SidebarView(model: SidebarModel(sections: fixture(), activeWorkspaceID: id("a")))
            weakSidebar = sidebar
            weakList = sidebar.list
            weakAutoscroll = sidebar.list.autoscroll
            weakPaging = sidebar.spacePaging
        }
        #expect(weakSidebar == nil)
        #expect(weakList == nil)
        #expect(weakAutoscroll == nil)
        #expect(weakPaging == nil)
    }
}
