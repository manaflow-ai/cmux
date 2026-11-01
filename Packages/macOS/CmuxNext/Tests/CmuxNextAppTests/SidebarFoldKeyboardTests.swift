import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Disclosure rows participate in the keyboard walk without selecting a workspace.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFoldKeyboardTests {
    private static let fold = SidebarDoneFoldID(section: .machine(.local), group: nil)

    @Test(arguments: [false, true])
    func arrowsReachAndReturnTogglesEachFold(showMore: Bool) throws {
        try withList { list in
            let key: SidebarRowKey = showMore ? .showMore(Self.fold) : .doneFold(Self.fold)
            let hidden = SidebarRowKey.workspace(WorkspaceID(showMore ? "w2" : "w4"))
            try press(code: 125, in: list)
            if !showMore { try press(code: 125, in: list) }
            #expect(list.model.activeWorkspaceID == WorkspaceID("w1"))
            #expect(list.displayed.row(for: hidden) == nil)
            try press(code: 36, in: list)
            #expect(list.displayed.row(for: key)?.isCollapsed == false)
            #expect(list.displayed.row(for: hidden) != nil)
            try press(code: 36, in: list)
            #expect(list.displayed.row(for: hidden) == nil)
            #expect(!list.inlineRename.isActive)
        }
    }

    @Test func tabSpaceAndDirectionalKeysOperateBothFolds() throws {
        try withList { list in
            try press(code: 48, in: list)
            try space(in: list)
            #expect(list.openShowMore.contains(Self.fold))
            try press(code: 123, in: list)
            #expect(list.openShowMore.isEmpty)
            try press(code: 124, in: list)
            try press(code: 124, in: list)
            #expect(list.openShowMore.contains(Self.fold), "Right must not close an open disclosure")
            try press(code: 48, in: list)
            try space(in: list)
            #expect(list.openDoneFolds.contains(Self.fold))
            try press(code: 48, flags: .shift, in: list)
            try space(in: list)
            #expect(list.openShowMore.isEmpty)
            #expect(list.openDoneFolds.contains(Self.fold))
        }
    }

    @Test func walkingBackFromAFoldSelectsThePreviousWorkspace() throws {
        try withList { list in
            try press(code: 125, in: list)
            try press(code: 125, in: list)
            try press(code: 126, in: list)
            try space(in: list)
            #expect(list.openShowMore.contains(Self.fold))
            try press(code: 126, in: list)
            #expect(list.model.activeWorkspaceID == WorkspaceID("w3"))
        }
    }

    @Test func aRemovedFoldCannotConsumeReturnOrRetainItsRing() throws {
        try withList { list in
            try press(code: 125, in: list)
            let row = try #require(list.rowViews[.showMore(Self.fold)])
            #expect((row.layer?.borderWidth ?? 0) > 0)
            list.model.filterText = "Workspace 0"
            list.reload(animated: false)
            #expect(list.focusedFold == nil)
            #expect(!SidebarGroupKeys(list: list).handle(try event(code: 36), flags: []))
            #expect(list.openShowMore.isEmpty)
            // The fold coming back must not bring back its old focus or ring.
            list.model.filterText = ""
            list.reload(animated: false)
            #expect(list.focusedFold == nil)
            let back = try #require(list.rowViews[.showMore(Self.fold)])
            #expect((back.layer?.borderWidth ?? 0) == 0)
            #expect(!SidebarGroupKeys(list: list).handle(try event(code: 36), flags: []))
            #expect(list.openShowMore.isEmpty)
        }
    }

    @Test func clickingAnotherFoldMovesFocusAndItsRingAway() throws {
        try withList { list in
            try press(code: 125, in: list)
            let showMore = try #require(list.rowViews[.showMore(Self.fold)])
            #expect((showMore.layer?.borderWidth ?? 0) > 0)
            try click(.doneFold(Self.fold), in: list)
            #expect(list.openDoneFolds.contains(Self.fold))
            #expect(list.focusedFold == .doneFold(Self.fold))
            #expect((showMore.layer?.borderWidth ?? 0) == 0)
            let done = try #require(list.rowViews[.doneFold(Self.fold)])
            #expect((done.layer?.borderWidth ?? 0) == 0, "A click focuses without a ring")
            try space(in: list)
            #expect(list.openShowMore.isEmpty, "Space must not act on the fold the click left")
            #expect(!list.openDoneFolds.contains(Self.fold))
        }
    }

    private func click(_ key: SidebarRowKey, in list: SidebarListView) throws {
        let row = try #require(list.displayed.row(for: key))
        let frame = list.frame(for: row)
        let at = list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: list.window?.windowNumber ?? 0, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { list.mouseDown(with: event) } else { list.mouseUp(with: event) }
        }
    }

    private func press(code: UInt16, flags: NSEvent.ModifierFlags = [], in list: SidebarListView) throws {
        list.keyDown(with: try event(code: code, flags: flags))
    }

    private func event(code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let characters = switch code {
        case 36: "\r"
        case 48: "\t"
        case 49: " "
        case 123: "\u{F702}" // left
        case 124: "\u{F703}" // right
        case 125: "\u{F701}" // down
        case 126: "\u{F700}" // up
        default: ""
        }
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func space(in list: SidebarListView) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                                                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        list.keyDown(with: event)
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
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)],
                                 activeWorkspaceID: WorkspaceID("w1"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView = list
        list.reload(animated: false)
        try body(list)
    }
}
