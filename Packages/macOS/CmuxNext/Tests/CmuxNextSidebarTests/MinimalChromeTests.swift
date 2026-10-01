import AppKit
import Testing
@testable import CmuxNextSidebar

/// The minimal sidebar: no search field, machine headers only with more than
/// one machine, second lines only for live status, hover-revealed buttons.
@MainActor @Suite struct MinimalChromeTests {
    func localOnly(_ nodes: [SidebarNode], collapsed: Bool = false) -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), isCollapsed: collapsed, nodes: nodes)]
    }

    @Test func soleMachineHasNoHeaderAndCannotHideItsRows() {
        let sections = localOnly([.workspace(w("a")), .workspace(w("b"))], collapsed: true)
        let layout = SidebarLayout.make(sections: sections, metrics: .standard)
        #expect(layout.rows.map(\.key) == [.workspace(id("a")), .workspace(id("b"))])
        var o = SidebarLayoutOptions()
        o.showsSoleMachineHeader = true
        #expect(SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.first?.key == .section(local))
    }

    @Test func pinnedAreaKeepsItsHeaderWithOneMachine() {
        var sections = fixture()
        sections.removeLast()
        let keys = SidebarLayout.make(sections: sections, metrics: .standard).rows.map(\.key)
        #expect(keys.contains(.section(.pinned)))
        #expect(!keys.contains(.section(local)))
    }

    @Test func machineHeadersReturnWithASecondMachine() {
        let keys = SidebarLayout.make(sections: fixture(), metrics: .standard).rows.map(\.key)
        #expect(keys.contains(.section(local)))
        #expect(keys.contains(.section(cloudSection)))
    }

    @Test func dropAboveTheFirstRowOfAHeaderlessListTargetsIndexZero() {
        let sections = localOnly([.workspace(w("a")), .workspace(w("b")), .workspace(w("c"))])
        let base = SidebarLayout.make(sections: sections, metrics: .standard)
        let target = DropResolver.resolve(y: 0, payload: .workspaces([id("c")]), base: base, sections: sections)
        #expect(target == .position(DropPosition(section: local, index: 0)))
    }

    @Test func onlyLiveStatusEarnsMoreLines() {
        let m = SidebarLayoutMetrics.standard
        let passive = SidebarWorkspace(id: id("a"), title: "a", subtitle: "~")
        let live = SidebarWorkspace(id: id("b"), title: "b", subtitle: "~",
                                    status: SidebarWorkspaceStatus(entries: [.init(key: "agent", text: "Claude: running tests")]))
        let blank = SidebarWorkspace(id: id("c"), title: "c", status: SidebarWorkspaceStatus())
        #expect(passive.liveStatus == nil)
        #expect(blank.liveStatus == nil)
        #expect(live.liveStatus?.lines == [.entry(.init(key: "agent", text: "Claude: running tests"))])
        #expect(m.height(for: passive) == m.rowHeight)
        #expect(m.height(for: blank) == m.rowHeight)
        #expect(m.height(for: live) == m.rowHeightWithSubtitle)
    }

    @Test func sidebarHasNoSearchFieldAndTypingDoesNotFilter() throws {
        let h = Harness()
        let fields = h.sidebar.allSubviews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(fields.isEmpty)
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
            context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        h.sidebar.list.keyDown(with: key)
        #expect(h.sidebar.model.filterText.isEmpty)
    }

    @Test func titlebarButtonsRevealOnHoverAndForTabDrags() {
        let h = Harness()
        #expect(!h.sidebar.isChromeRevealed)
        #expect(h.sidebar.newButton.alphaValue == 0)
        h.sidebar.setChromeRevealed(true)
        #expect(h.sidebar.isChromeRevealed)
        h.sidebar.setChromeRevealed(false)
        // A tab drag over the "+" reveals it and targets a new workspace.
        let button = h.sidebar.newButton.frame
        let screen = h.window.convertToScreen(h.sidebar.convert(NSRect(x: button.midX, y: button.midY, width: 0, height: 0), to: nil)).origin
        let hit = h.sidebar.tabDragUpdate(screenPoint: screen, sourceMachine: .local)
        #expect(h.sidebar.isChromeRevealed)
        if case .newWorkspace? = hit?.drop {} else { Issue.record("expected a new-workspace drop, got \(String(describing: hit))") }
        h.sidebar.tabDragExited()
    }

    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView

        init(sections: [SidebarSection] = fixture()) {
            sidebar = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
        }
    }
}

extension NSView {
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }
}
