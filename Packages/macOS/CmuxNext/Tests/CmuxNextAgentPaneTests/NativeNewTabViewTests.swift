import AppKit
@testable import CmuxNextAgentPane
import Testing

/// The native New Tab page is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): its field exists before
/// any layout, typing in it changes the rows in the same turn, Up and Down move the highlight, Return
/// and a click run a row, and the switch sets the kind.
@MainActor @Suite(.serialized)
struct NativeNewTabViewTests {
    private struct Calls {
        var submits: [(String, AgentPaneTabKind)] = []
        var jumps: [String] = []
    }

    private static func page() -> AgentPaneNewTab {
        let omnibar = AgentPaneOmnibar(
            tabs: [AgentPaneOmnibar.Tab(id: "t1", kind: .browser, title: "Vite guide", detail: "vite.dev/guide", workspace: "web")],
            workspaces: [AgentPaneOmnibar.Workspace(id: "w1", name: "app-efficiency")],
            actions: [AgentPaneOmnibar.Action(id: "toggleSidebar", title: "Toggle Sidebar", detail: "View", keycaps: ["⌘", "B"])],
            history: [AgentPaneOmnibar.Page(url: "https://news.ycombinator.com/", title: "Hacker News")]
        )
        return AgentPaneNewTab(kind: .agent, omnibar: omnibar)
    }

    private final class Box { var calls = Calls() }

    private static func make() -> (NativeNewTabHostingView, NativeNewTabModel, Box, NSWindow) {
        let box = Box()
        let actions = NativeNewTabActions(submit: { text, kind, _ in box.calls.submits.append((text, kind)) },
                                          jump: { _, id in box.calls.jumps.append(id) })
        let model = NativeNewTabModel(page: page(), actions: actions)
        let host = NativeNewTabView.hosted(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = window.contentLayoutRect
        window.contentView = host
        return (host, model, box, window)
    }

    private static func enter(_ text: String, into host: NativeNewTabHostingView) throws {
        let field = try #require(host.fieldView as? NSTextField)
        field.stringValue = text
        host.page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private static func command(_ selector: Selector, in host: NativeNewTabHostingView) -> Bool {
        host.page.control(host.page.fieldView, textView: NSTextView(), doCommandBy: selector)
    }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    @Test func theFieldExistsBeforeAnyLayoutAndTakesTheKeyboard() throws {
        let (host, _, _, window) = Self.make()
        defer { window.close() }
        let field = try #require(host.fieldView as? NSTextField)
        #expect(field.accessibilityIdentifier() == "cmux.nativeNewTab.field")
        #expect(!Self.descendants(of: host).contains { NSStringFromClass(type(of: $0)).contains("NSHostingView") })
        var ready = 0
        host.onFieldReady = { ready += 1 }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(ready == 1, "onFieldReady runs once, at the first layout")
        #expect(window.makeFirstResponder(field))
    }

    @Test func typingChangesTheRowsInTheSameTurn() throws {
        let (host, model, _, window) = Self.make()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.page.rows.count == model.rows.count)
        try Self.enter("vite", into: host)
        #expect(model.text == "vite")
        #expect(host.page.rows.map(\.content?.title) == model.rows.map { NativeNewTabRowContent($0, strings: NativeNewTabStrings()).title })
        #expect(host.page.rows.first?.selected == true)
        host.layoutSubtreeIfNeeded()
        let field = try #require(host.fieldView)
        let rows = host.page.rows
        #expect(rows.allSatisfy { $0.frame.width > 0 && $0.frame.height == NativeNewTabRowView.height })
        #expect(rows.allSatisfy { host.page.convert($0.bounds, from: $0).minY > host.page.convert(field.bounds, from: field).minY },
                "the rows sit under the field")
    }

    @Test func downUpAndReturnRunTheHighlightedRow() throws {
        let (host, model, box, window) = Self.make()
        defer { window.close() }
        try Self.enter("vite", into: host)
        #expect(Self.command(#selector(NSResponder.moveDown(_:)), in: host))
        #expect(model.selectedIndex == 1)
        #expect(host.page.rows.map(\.selected) == [false, true])
        #expect(Self.command(#selector(NSResponder.moveUp(_:)), in: host))
        #expect(model.selectedIndex == 0)
        #expect(Self.command(#selector(NSResponder.moveDown(_:)), in: host))
        #expect(Self.command(#selector(NSResponder.insertNewline(_:)), in: host))
        #expect(box.calls.jumps == ["t1"])
        #expect(!Self.command(#selector(NSResponder.moveLeft(_:)), in: host), "other keys stay with the field")
    }

    @Test func aClickRunsItsRow() throws {
        let (host, _, box, window) = Self.make()
        defer { window.close() }
        try Self.enter("vite", into: host)
        host.layoutSubtreeIfNeeded()
        let ask = try #require(host.page.rows.first)
        #expect(ask.accessibilityPerformPress())
        #expect(box.calls.submits.map(\.0) == ["vite"])
        #expect(box.calls.submits.map(\.1) == [.agent])
    }

    /// Review finding: a row the list no longer shows kept its frame and action, and took the click
    /// meant for the row now drawn there. A real click (hit test, then mouse up) after the list
    /// shrinks runs the row it lands on.
    @Test func aClickAfterTheListShrinksRunsTheRowUnderIt() throws {
        let (host, model, box, window) = Self.make()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let before = model.rows.count
        try #require(before >= 2, "the empty field lists the open tab and the workspace")
        try Self.enter("zzz", into: host)
        host.layoutSubtreeIfNeeded()
        let shown = host.page.rows
        try #require(shown.count < before)
        let row = try #require(shown.first)
        let center = NSPoint(x: row.bounds.midX, y: row.bounds.midY)
        #expect(host.page.hitTest(host.convert(center, from: row)) === row, "a hidden row covers the shown one")
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(center, to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 0))
        row.mouseUp(with: event)
        #expect(box.calls.submits.map(\.0) == ["zzz"])
        #expect(box.calls.jumps.isEmpty, "the click ran a row the list no longer shows")
    }

    @Test func theSwitchSetsTheKind() throws {
        let (host, model, box, window) = Self.make()
        defer { window.close() }
        let kinds = host.page.kindControl
        #expect(kinds.selectedSegment == AgentPaneTabKind.allCases.firstIndex(of: .agent))
        let terminal = try #require(AgentPaneTabKind.allCases.firstIndex(of: .terminal))
        kinds.selectedSegment = terminal
        _ = kinds.sendAction(kinds.action, to: kinds.target)
        #expect(model.kind == .terminal)
        try Self.enter("ls", into: host)
        #expect(host.page.rows.first?.content?.title == NativeNewTabStrings().run("ls"))
        #expect(Self.command(#selector(NSResponder.insertNewline(_:)), in: host))
        #expect(box.calls.submits.map(\.0) == ["ls"])
        #expect(box.calls.submits.map(\.1) == [.terminal])
    }

    @Test func anAdoptedPageShowsTheNewContext() throws {
        let (host, model, _, window) = Self.make()
        defer { window.close() }
        try Self.enter("vite", into: host)
        var next = Self.page()
        next.kind = .browser
        model.adopt(page: next, actions: NativeNewTabActions(), paletteActions: nil)
        host.page.render()
        let field = try #require(host.fieldView as? NSTextField)
        #expect(field.stringValue.isEmpty)
        #expect(host.page.kindControl.selectedSegment == AgentPaneTabKind.allCases.firstIndex(of: .browser))
    }
}
