@testable import CmuxNextSidebar
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import AppKit
import Testing

/// The sidebar's half of `HoverCardCoordinator.warm()` (goal sidebar-hover-instant): its card body is made ahead,
/// configured for the first visible workspace row as a real card would be, with none of a shown card's wiring (row
/// actions, sampling, ticker), and the first real card reuses that same view instead of building one.
@MainActor @Suite(.closesItsWindows)
struct SidebarHoverCardWarmTests {
    @Test func theWarmBodyIsTheFirstRowsCardAndTheFirstCardReusesIt() throws {
        _ = NSApplication.shared
        var first = SidebarWorkspace(id: WorkspaceID("first"), title: "First workspace", directory: "~/one", branch: "main")
        first.tabs = [SidebarTab(id: TabID("shell"), title: "Shell")]
        let second = SidebarWorkspace(id: WorkspaceID("second"), title: "Second workspace", directory: "~/two", branch: "dev")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(first), .workspace(second)])],
                                 activeWorkspaceID: WorkspaceID("second"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { list.hoverCards.dismiss(.action); window.contentView = nil; window.close() }
        window.contentView = list
        list.reload(animated: false)

        let warm = try #require(list.hoverCard.hoverCardWarmBody())
        let card = try #require(warm.view as? WorkspaceHoverCardView)
        #expect(warm.placement == .besideRow)
        #expect(card.lines.contains { $0.contains("First workspace") }, "\(card.lines)")
        // Nothing a shown card wires: a click on this never-shown body could not select or close a tab.
        #expect(card.tabList.onSelect == nil)
        #expect(card.tabList.onClose == nil)
        #expect(!list.hoverCard.resources.isOpen)
        // Made once.
        #expect(list.hoverCard.hoverCardWarmBody() == nil)

        let shown = try #require(list.hoverCard.hoverCardBody(for: WorkspaceHoverCardController.targetID(WorkspaceID("second")))?.view)
        #expect(shown === card, "the first card built another body")
        #expect(card.lines.contains { $0.contains("Second workspace") }, "\(card.lines)")
    }
}
