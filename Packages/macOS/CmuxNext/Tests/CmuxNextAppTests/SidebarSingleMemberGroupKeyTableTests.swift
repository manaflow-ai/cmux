import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Review on #27875 at 5f43c963: every group key, pressed on a focused group drawn as its one row
/// (`SidebarLayout+SoleMember`), does what it does on that group's header. Each case starts in a fresh sidebar with the
/// keyboard on the group "release-coord" (one member of the same name), at the top level or under "Outer", collapsed
/// (its header draws) or open (its one row draws, and is its header's stop).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSingleMemberGroupKeyTableTests {
    nonisolated static let before = GroupID("g-before"), outer = GroupID("g-outer"), group = GroupID("g-coord"), after = GroupID("g-after")
    nonisolated static let coord = WorkspaceID("w-coord"), loose = WorkspaceID("w-a"), inOuter = WorkspaceID("w-o1")

    enum Key: String, CaseIterable {
        case tab, shiftTab, up, down, left, right, returnKey, space
    }

    /// What a key leaves: the focused group (nil: none) and the active workspace; whether the group is collapsed.
    struct Outcome: Equatable {
        var focused: GroupID?
        var active: WorkspaceID?
        var collapsed: Bool
        var editorOpen = false
    }

    struct Case: CustomStringConvertible {
        let nested: Bool, collapsed: Bool, key: Key
        var description: String { "\(nested ? "nested" : "top-level") \(collapsed ? "collapsed" : "open") \(key.rawValue)" }
    }

    nonisolated static let cases: [Case] = [false, true].flatMap { nested in
        [false, true].flatMap { collapsed in Key.allCases.map { Case(nested: nested, collapsed: collapsed, key: $0) } }
    }

    /// The header's behavior on base, from the focused group.
    nonisolated static func expected(_ c: Case) -> Outcome {
        switch c.key {
        case .tab: return Outcome(focused: after, active: loose, collapsed: c.collapsed)
        case .shiftTab: return Outcome(focused: c.nested ? outer : before, active: loose, collapsed: c.collapsed)
        // The stop drawn above the group: the loose row, or Outer's own member.
        case .up: return Outcome(focused: nil, active: c.nested ? inOuter : loose, collapsed: c.collapsed)
        // Into the open group's member, or past the collapsed one to the next header.
        case .down: return c.collapsed ? Outcome(focused: after, active: loose, collapsed: true) : Outcome(focused: nil, active: coord, collapsed: false)
        case .left: return Outcome(focused: group, active: loose, collapsed: true)
        case .right: return c.collapsed ? Outcome(focused: group, active: loose, collapsed: false) : Outcome(focused: nil, active: coord, collapsed: false)
        case .returnKey: return Outcome(focused: group, active: loose, collapsed: c.collapsed, editorOpen: true)
        case .space: return Outcome(focused: group, active: loose, collapsed: !c.collapsed)
        }
    }

    @Test(arguments: cases) func aGroupKeyOnTheFocusedOneRowGroupActsAsOnItsHeader(_ c: Case) throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func pair(_ prefix: String) -> [SidebarWorkspace] {
            [SidebarWorkspace(id: WorkspaceID("w-\(prefix)1"), title: "\(prefix)1"), SidebarWorkspace(id: WorkspaceID("w-\(prefix)2"), title: "\(prefix)2")]
        }
        var coordGroup = SidebarGroup(id: Self.group, name: "release-coord", isCollapsed: c.collapsed,
                                      workspaces: [SidebarWorkspace(id: Self.coord, title: "release-coord")])
        var nodes: [CmuxNextSidebar.SidebarNode] = [
            .group(SidebarGroup(id: Self.before, name: "Before", workspaces: pair("p"))),
            .workspace(SidebarWorkspace(id: Self.loose, title: "A")),
        ]
        if c.nested {
            nodes.append(.group(SidebarGroup(id: Self.outer, name: "Outer", workspaces: [SidebarWorkspace(id: Self.inOuter, title: "O1")])))
            coordGroup.parent = Self.outer
            coordGroup.depth = 1
        }
        nodes += [.group(coordGroup), .group(SidebarGroup(id: Self.after, name: "After", workspaces: pair("q")))]
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: Self.loose)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        let list = sidebar.list
        list.groupEditor.ordersFront = false
        defer {
            list.groupEditor.hide()
            list.groupEditor.bubble?.close()
            window.close()
        }
        list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        if !c.collapsed { #expect(list.displayed.row(for: .workspace(Self.coord))?.standsForGroup == true, "the open group did not draw as its one row") }
        #expect(c.collapsed == (list.displayed.row(for: .group(Self.group)) != nil), "the group's header draws only while it is collapsed")

        let keys = SidebarGroupKeys(list: list)
        keys.setFocus(Self.group)
        list.reload(animated: false)
        let ring = c.collapsed ? (list.rowViews[.group(Self.group)] as? GroupHeaderRowView)?.isKeyboardFocused
            : (list.rowViews[.workspace(Self.coord)] as? WorkspaceRowView)?.isKeyboardFocused
        #expect(ring == true, "\(c): the focused group drew no focus ring")

        let (characters, code, flags): (String, UInt16, NSEvent.ModifierFlags) = switch c.key {
        case .tab: ("\t", 48, [])
        case .shiftTab: ("\t", 48, [.shift])
        case .up: (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126, [])
        case .down: (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125, [])
        case .left: (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), 123, [])
        case .right: (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), 124, [])
        case .returnKey: ("\r", 36, [])
        case .space: (" ", 49, [])
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: code))
        #expect(keys.handle(event, flags: flags), "\(c): the list did not take the key")
        list.reload(animated: false)
        let got = Outcome(focused: list.focusedGroup, active: model.activeWorkspaceID, collapsed: model.group(Self.group)?.isCollapsed ?? false,
                          editorOpen: list.groupEditor.shownGroup == Self.group)
        #expect(got == Self.expected(c), "\(c)")
    }
}
