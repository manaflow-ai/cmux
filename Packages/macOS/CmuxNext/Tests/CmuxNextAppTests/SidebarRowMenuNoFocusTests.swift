import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-21 (u8646): "clicking 3 dots here should not focus workspace". A workspace
/// row's more button ran `model.click` before it opened the row's menu, so the press switched
/// the window to that workspace. A hover accessory (⋮, ✕) and a right-click act on the row in
/// place: the menu opens for that row, the shown workspace and the selection stay as they were.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowMenuNoFocusTests {
    /// A sidebar of two workspaces in a never-shown window, `w0` shown, with every intent recorded.
    static func sidebar() throws -> (SidebarView, NSWindow, first: WorkspaceID, second: WorkspaceID, intents: () -> [SidebarIntent],
                                     targets: () -> [SidebarContextTarget]) {
        let (sidebar, _) = try GroupPaletteDefaultTests.sidebar([.red, .blue])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        window.contentView?.addSubview(sidebar)
        sidebar.list.groupEditor.ordersFront = false
        final class Log { var intents: [SidebarIntent] = []; var targets: [SidebarContextTarget] = [] }
        let log = Log()
        sidebar.contextMenuProvider = { target in
            log.targets.append(target)
            return SidebarMenuAnchorTests.wideMenu()
        }
        sidebar.list.menuPresenter = { _, _, _ in }
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let model = sidebar.list.model
        let rows = sidebar.list.rowViews.values.compactMap { $0 as? WorkspaceRowView }
        try #require(rows.count >= 2, "the fixture needs two workspace rows")
        let workspaceIDs = rows.compactMap { row -> WorkspaceID? in
            if case let .workspace(id) = row.key { id } else { nil }
        }.sorted { $0.rawValue < $1.rawValue }
        let (first, second) = (workspaceIDs[0], workspaceIDs[1])
        model.click(first)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        model.onIntent = { log.intents.append($0) }
        return (sidebar, window, first, second, { log.intents }, { log.targets })
    }

    static func selects(_ intents: [SidebarIntent]) -> Bool {
        intents.contains { if case .select = $0 { true } else { false } }
    }

    @Test func theMoreButtonOpensTheRowMenuWithoutFocusingTheRow() throws {
        let (sidebar, window, first, second, intents, targets) = try Self.sidebar()
        defer { window.close() }
        let model = sidebar.list.model
        let row = try #require(sidebar.list.rowViews[.workspace(second)] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let more = row.moreButton
        #expect(more.sendAction(more.action, to: more.target), "the row's more button has no action")
        #expect(!Self.selects(intents()), "the more button selected a workspace: \(intents())")
        #expect(model.activeWorkspaceID == first, "the shown workspace changed to \(String(describing: model.activeWorkspaceID))")
        #expect(model.selection == [first], "the selection changed to \(model.selection)")
        guard case let .workspaces(ids)? = targets().last else {
            Issue.record("the menu was built for \(String(describing: targets().last))")
            return
        }
        #expect(ids == [second], "the menu acts on \(ids), not the row")
    }

    @Test func aRightClickOpensTheRowMenuWithoutFocusingTheRow() throws {
        let (sidebar, window, first, second, intents, targets) = try Self.sidebar()
        defer { window.close() }
        let list = sidebar.list
        let row = try #require(list.displayed.row(for: .workspace(second)))
        let frame = list.frame(for: row)
        let point = list.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        #expect(list.menu(for: event) != nil)
        #expect(!Self.selects(intents()), "the right-click selected a workspace: \(intents())")
        #expect(list.model.activeWorkspaceID == first)
        #expect(list.model.selection == [first])
        guard case let .workspaces(ids)? = targets().last else {
            Issue.record("the menu was built for \(String(describing: targets().last))")
            return
        }
        #expect(ids == [second])
    }

    /// A row inside a multi-selection keeps acting on the whole selection.
    @Test func theMoreButtonOnASelectedRowActsOnTheSelection() throws {
        let (sidebar, window, first, second, intents, targets) = try Self.sidebar()
        defer { window.close() }
        let model = sidebar.list.model
        model.toggleSelection(second)
        let row = try #require(sidebar.list.rowViews[.workspace(second)] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let more = row.moreButton
        #expect(more.sendAction(more.action, to: more.target))
        #expect(!Self.selects(intents()))
        #expect(model.activeWorkspaceID == first)
        guard case let .workspaces(ids)? = targets().last else {
            Issue.record("the menu was built for \(String(describing: targets().last))")
            return
        }
        #expect(Set(ids) == [first, second])
    }

    /// The press reaches the button, never the list's row mouse-down (which selects on press).
    @Test func aPressOnTheHoverButtonsHitsTheButtonNotTheRow() throws {
        let (sidebar, window, _, second, _, _) = try Self.sidebar()
        defer { window.close() }
        let list = sidebar.list
        let row = try #require(list.rowViews[.workspace(second)] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        for button in [row.moreButton, row.closeButton] as [NSView] where !button.isHidden {
            let center = row.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: list.superview)
            #expect(list.hitTest(center) === button, "a press on \(button) lands on \(String(describing: list.hitTest(center)))")
        }
    }
}
