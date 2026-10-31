import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEmptyWorkspaceHintTests {
    @Test(arguments: SidebarDensity.allCases, [false, true])
    func emptyWorkspaceShowsCreationHintBelowTitle(_ density: SidebarDensity, _ minimal: Bool) throws {
        _ = NSApplication.shared
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        var options = SidebarLayoutOptions()
        options.minimal = minimal
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        let geometry = try #require(layout.row(for: .emptySection(section.id)))
        let view = EmptySectionRowView(key: geometry.key)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: geometry.height)
        view.configure(pinned: false, shortcut: "⌘N")
        view.layoutSubtreeIfNeeded()
        let labels = view.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden }
        let title = try #require(labels.first { $0.stringValue == "No workspaces" })
        let hint = try #require(labels.first { $0.stringValue == "New workspace: + or ⌘N" })
        #expect(hint.frame.minY >= title.frame.maxY)
        #expect(hint.frame.minX == title.frame.minX)
        #expect(title.frame.minY >= 0)
        #expect(hint.frame.maxY <= view.bounds.height)
        #expect(hint.font == SidebarStyle.subtitleFont)
    }

    @Test(arguments: ["⌘N", "⌘T", "⇧⌘K", "⌃B C", nil] as [String?])
    func renderedHintUsesEffectiveShortcut(_ shortcut: String?) {
        _ = NSApplication.shared
        let view = EmptySectionRowView(key: .emptySection(.machine(.local)))
        view.configure(pinned: false, shortcut: shortcut)
        let expected = shortcut.map { "New workspace: + or \($0)" } ?? "New workspace: +"
        let labels = view.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden }
        #expect(labels.map(\.stringValue) == ["No workspaces", expected])
    }

    @Test func shortcutChangeRefreshesVisibleHint() throws {
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
        for shortcut in ["⌘N", "⌘T", nil] as [String?] {
            model.newWorkspaceShortcut = shortcut
            sidebar.renderNow()
            let row = try #require(sidebar.list.rowViews[.emptySection(section.id)] as? EmptySectionRowView)
            let expected = shortcut.map { "New workspace: + or \($0)" } ?? "New workspace: +"
            #expect(row.subviews.compactMap { $0 as? ChromeLabel }.contains { !$0.isHidden && $0.stringValue == expected })
        }
    }

    @Test func reusedPinnedDropZoneHidesCreationHint() {
        _ = NSApplication.shared
        let view = EmptySectionRowView(key: .emptySection(.machine(.local)))
        view.configure(pinned: false, shortcut: "⌘N")
        view.prepareForReuse(key: .emptySection(.pinned))
        view.configure(pinned: true, shortcut: "⌘N")
        let labels = view.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden }
        #expect(labels.map(\.stringValue) == ["Drop here to pin"])
        view.prepareForReuse(key: .emptySection(.machine(.local)))
        view.configure(pinned: false, shortcut: "⌘N")
        #expect(view.subviews.compactMap { $0 as? ChromeLabel }.contains { !$0.isHidden && $0.stringValue == "New workspace: + or ⌘N" })
    }
}
