import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFoldAccessibilityTests {
    static let fold = SidebarDoneFoldID(section: .machine(.local), group: nil)

    @Test(arguments: [false, true])
    func pressOpensAndClosesTheFold(showMore: Bool) throws {
        try withList { list in
            let key: SidebarRowKey = showMore ? .showMore(Self.fold) : .doneFold(Self.fold)
            let hidden = SidebarRowKey.workspace(WorkspaceID(showMore ? "w2" : "w4"))
            let row = try #require(list.rowViews[key] as? SidebarDoneFoldRowView)
            #expect(!row.isAccessibilityExpanded())
            #expect(list.displayed.row(for: hidden) == nil)
            #expect(row.accessibilityPerformPress())
            #expect(list.displayed.row(for: hidden) != nil)

            let opened = try #require(list.rowViews[key] as? SidebarDoneFoldRowView)
            #expect(opened.isAccessibilityExpanded())
            #expect(opened.accessibilityPerformPress())
            #expect(list.displayed.row(for: hidden) == nil)
            #expect(list.displayed.row(for: key)?.isCollapsed == true)
        }
    }

    @Test func reusedRowActsOnItsNewFoldOnly() throws {
        try withList { list in
            let row = SidebarDoneFoldRowView(key: .doneFold(Self.fold))
            list.wire(row, key: .doneFold(Self.fold))
            row.prepareForReuse(key: .showMore(Self.fold))
            #expect(!row.accessibilityPerformPress(), "a row between bindings must not activate its old fold")
            list.wire(row, key: .showMore(Self.fold))
            row.configure(try #require(list.displayed.row(for: .showMore(Self.fold))))
            #expect(row.accessibilityPerformPress())
            #expect(list.openShowMore.contains(Self.fold))
            #expect(!list.openDoneFolds.contains(Self.fold))
        }
    }

    @Test func hiddenRowCannotActivateItsFold() throws {
        try withList { list in
            let row = try #require(list.rowViews[.doneFold(Self.fold)] as? SidebarDoneFoldRowView)
            row.isHidden = true
            #expect(!row.accessibilityPerformPress())
            #expect(list.openDoneFolds.isEmpty)
        }
    }

    private func withList(_ body: (SidebarListView) throws -> Void) throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        TunableStore.shared.set(SidebarTunables.groupRowLimit.key, .number(2))
        defer {
            TunableStore.shared.set(SidebarTunables.doneFold.key, nil)
            TunableStore.shared.set(SidebarTunables.groupRowLimit.key, nil)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes = (0..<5).map { index -> SidebarNode in
            var workspace = SidebarWorkspace(id: WorkspaceID("w\(index)"), title: "Workspace \(index)")
            if index == 4 { workspace.taskStatus = .done }
            return .workspace(workspace)
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = list
        list.reload(animated: false)
        try body(list)
    }
}
