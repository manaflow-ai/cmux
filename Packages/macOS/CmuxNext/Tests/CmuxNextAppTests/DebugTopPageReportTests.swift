import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextSidebar
import Testing

/// GUI proofs click the real sidebar items and read back the shown page
/// (TOP-SECTION-ITEMS-ARE-PAGES): `debug.sidebar_rows` lists every layout
/// item (top and bottom regions) with its ref, region, active state and
/// window frame, and `debug.windows` names each window's page (the state's
/// and the one drawn).
@MainActor
struct DebugTopPageReportTests {
    @Test func sidebarRowsListTheLayoutItemsWithTheirState() async throws {
        let (services, window, _, _) = try await TopPageTests.window()
        window.sidebar.model.selectedItem = .topItem(LayoutItemID("itm_app_store"))
        let items = DebugSidebarRows.items(of: window)
        let store = try #require(items.first { $0["id"]?.stringValue == "itm_app_store" })
        #expect(store["ref_kind"]?.stringValue == "app")
        #expect(store["ref"]?.stringValue == "cmux/app-store")
        #expect(store["region"]?.stringValue == "top")
        #expect(store["active"]?.boolValue == true)
        #expect(store["window_frame"] != nil, "a frame or null, always present")
        #expect(items.contains { $0["id"]?.stringValue == "itm_settings" && $0["region"]?.stringValue == "bottom" })
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func windowsReportTheShownPage() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        let before = WindowInvariants.pageFields(state: state, controller: window)
        #expect(before["page"] == .null, "no page: the window shows its workspace")
        #expect(before["shown_page"] == .null)
        _ = TopPages.show(TopPageTests.route, services: services, in: state)
        let after = WindowInvariants.pageFields(state: state, controller: window)
        #expect(after["page"]?.stringValue == TopPageTests.route.rawValue)
        #expect(after["shown_page"]?.stringValue == TopPageTests.route.rawValue)
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
