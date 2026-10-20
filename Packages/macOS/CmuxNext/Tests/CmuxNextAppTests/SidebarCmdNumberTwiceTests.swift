import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-19: "If I press Command-1 twice, the first time Home is highlighted but the
/// second time nothing is highlighted." Cmd-`n` on the item it already selected keeps that item
/// selected and drawn selected (its band or block item active, or its list row selected); it never
/// clears the selection. Runs the app's action registry (the key binding's action) against a
/// same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SidebarCmdNumberTwiceTests {
    /// What the sidebar draws selected: the active top item (band or block), else the selected row.
    static func drawnSelection(_ view: SidebarView) -> String {
        if let item = view.list.activeTopItem ?? view.aboveRegion.activeItem { return "item:\(item.rawValue)" }
        return view.list.selectedRowKey.map { "row:\($0)" } ?? "nothing"
    }

    static func expectedDrawn(_ item: SidebarItem?, _ view: SidebarView) -> String {
        switch item {
        case let .topItem(id)?: "item:\(id.rawValue)"
        case let .workspace(id)?: view.list.displayed.row(for: .workspace(id)) == nil ? "nothing" : "row:\(SidebarRowKey.workspace(id))"
        case let .group(id)?: "row:\(SidebarRowKey.group(id))"
        case nil: "nothing"
        }
    }

    /// Lets the window state reach the sidebar (its observation hop and the selection hold's limit).
    static func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    @Test(arguments: [1, 2])
    func pressingCmdNumberTwiceKeepsItsItemSelectedAndDrawn(_ number: Int) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let view = window.sidebar.container.sidebarView
            let model = window.sidebar.model
            let picked = try #require(model.itemOrder.pick(number, SidebarNavigation.settings(services)), "Cmd-\(number) picks nothing")
            #expect(services.registry.perform("selectWorkspaceByNumber", argument: "\(number)"))
            try await Self.settle()
            let first = (model.selectedItem, Self.drawnSelection(view))
            #expect(first.1 != "nothing", "the first Cmd-\(number) drew nothing selected (picked \(picked), model \(String(describing: first.0)))")
            #expect(services.registry.perform("selectWorkspaceByNumber", argument: "\(number)"))
            try await Self.settle()
            let second = (model.selectedItem, Self.drawnSelection(view))
            #expect(second.0 == first.0, "the second Cmd-\(number) changed the selection from \(String(describing: first.0)) to \(String(describing: second.0)) (page \(String(describing: window.state.page)), workspace \(window.state.workspaceID ?? "nil"))")
            #expect(second.1 == first.1, "the second Cmd-\(number) drew \(second.1), the first \(first.1)")
            #expect(second.1 == Self.expectedDrawn(second.0, view) && second.1 != "nothing", "after the second Cmd-\(number) the sidebar draws \(second.1)")
        }
    }
}
