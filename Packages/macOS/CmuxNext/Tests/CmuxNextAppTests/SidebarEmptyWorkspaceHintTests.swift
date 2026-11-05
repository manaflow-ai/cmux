import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// An empty workspace list draws nothing under Home, as classic draws nothing there: no
/// "No workspaces" and no "New workspace: + or ⌘N" (https://github.com/manaflow-ai/cmux/issues/32728).
/// The row stays, one plain row high, as the list's drop target; Pinned's still says "Drop here to pin".
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEmptyWorkspaceHintTests {
    @Test(arguments: SidebarDensity.allCases, [false, true])
    func emptyWorkspaceListDrawsNoText(_ density: SidebarDensity, _ minimal: Bool) throws {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        var options = SidebarLayoutOptions()
        options.minimal = minimal
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        let geometry = try #require(layout.row(for: .emptySection(section.id)))
        #expect(geometry.height == SidebarLayoutMetrics.standard.emptySectionHeight)
        let view = EmptySectionRowView(key: geometry.key)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: geometry.height)
        view.configure(pinned: false)
        view.layoutSubtreeIfNeeded()
        #expect(view.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden && !$0.stringValue.isEmpty }.isEmpty)
    }

    @Test func liveSidebarWithNoWorkspacesDrawsNoText() throws {
        _ = NSApplication.shared
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        let model = SidebarModel(sections: [section])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        defer { window.close() }
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        let row = try #require(sidebar.list.rowViews[.emptySection(section.id)] as? EmptySectionRowView)
        #expect(row.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden && !$0.stringValue.isEmpty }.isEmpty)
    }

    @Test func reusedRowSwitchesBetweenPinnedDropZoneAndBlankList() {
        _ = NSApplication.shared
        let view = EmptySectionRowView(key: .emptySection(.machine(.local)))
        view.configure(pinned: false)
        view.prepareForReuse(key: .emptySection(.pinned))
        view.configure(pinned: true)
        let visible = { view.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden && !$0.stringValue.isEmpty }.map(\.stringValue) }
        #expect(visible() == ["Drop here to pin"])
        view.prepareForReuse(key: .emptySection(.machine(.local)))
        view.configure(pinned: false)
        #expect(visible().isEmpty)
    }
}
