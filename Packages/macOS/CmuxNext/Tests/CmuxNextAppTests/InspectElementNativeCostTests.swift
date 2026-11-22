import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Point at Element over native UI (ask-5077a4ec48) costs nothing until a pick starts: no monitor, overlay or
/// element state exists while idle. While a pick runs, a move over a named native object (a tab, a pane, a sidebar
/// row) outlines it and a click picks it instead of reaching the view. The suite also times the picker's cost per
/// mouse move over a deep native view tree (`INSPECT-BENCH` lines in the log), the same loop as before native picking
/// came back, so the two runs compare.
@MainActor @Suite(.serialized, .closesItsWindows) struct InspectElementNativeCostTests {
    /// A window whose content is `depth` nested views, each level with `siblings` neighbours
    /// that a hit-test scans first; returns the window and the deepest view's centre (screen).
    private func deepNativeWindow(depth: Int = 40, siblings: Int = 12) -> (NSWindow, NSPoint) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var parent: NSView = window.contentView!
        for _ in 0..<depth {
            let inset = parent.bounds.insetBy(dx: 4, dy: 4)
            for index in 0..<siblings {
                parent.addSubview(NSView(frame: NSRect(x: inset.minX + CGFloat(index), y: inset.minY, width: 1, height: 1)))
            }
            let child = NSView(frame: inset)
            parent.addSubview(child, positioned: .below, relativeTo: nil)
            parent = child
        }
        let centre = parent.convert(NSPoint(x: parent.bounds.midX, y: parent.bounds.midY), to: nil)
        return (window, window.convertPoint(toScreen: centre))
    }

    /// A tab strip whose tabs are accessibility children (as `TabStripView`'s layer cells are).
    final class Strip: NSView {
        var tabs: [NSAccessibilityElement] = []
        override func accessibilityChildren() -> [Any]? { tabs }
    }

    /// A window with a sidebar workspace row, a tab strip with one tab, and a pane holding an unnamed view.
    static func nativeWindow() -> (window: NSWindow, row: NSView, tab: NSRect, pane: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let row = NSTextField(labelWithString: "api")
        row.frame = NSRect(x: 8, y: 540, width: 200, height: 28)
        row.setAccessibilityIdentifier("cmux.sidebar.workspace.w1")
        row.setAccessibilityLabel("api")
        content.addSubview(row)
        let strip = Strip(frame: NSRect(x: 220, y: 560, width: 670, height: 32))
        strip.setAccessibilityIdentifier("cmux.tabs.strip")
        content.addSubview(strip)
        let tabRect = NSRect(x: 230, y: 562, width: 160, height: 28)
        let tab = NSAccessibilityElement()
        tab.setAccessibilityIdentifier("cmux.tabs.tab.t1")
        tab.setAccessibilityLabel("notes.md")
        tab.setAccessibilityRole(.radioButton)
        tab.setAccessibilityFrame(window.convertToScreen(tabRect))
        strip.tabs = [tab]
        let pane = NSView(frame: NSRect(x: 220, y: 8, width: 670, height: 540))
        pane.setAccessibilityIdentifier("cmux.layout.pane.p1")
        pane.addSubview(NSView(frame: pane.bounds.insetBy(dx: 10, dy: 10)))
        content.addSubview(pane)
        return (window, row, tabRect, pane)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func inspector(for window: NSWindow) -> UIInspectorController {
        UIInspectorController(host: .init(pages: { [] }, activeWindow: { [weak window] in window }, capture: { _ in nil }))
    }

    private func withInspectorOn(_ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.pointerInspector.descriptor])
        TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, .bool(true))
        defer { TunableStore.shared.set(AgentPaneTunables.pointerInspector.key, nil) }
        try body()
    }

    @Test func idleCostsNothing() {
        withInspectorOn {
            let services = AppServices(environment: AppEnvironment.current([:]))
            let inspector = services.uiInspector
            #expect(!inspector.isPicking, "a monitor runs before any pick")
            #expect(!inspector.native.isShowing && inspector.native.current == nil, "native state exists before any pick")
            print("INSPECT-BENCH idle: monitor \(inspector.isPicking ? 1 : 0), overlay \(inspector.native.isShowing ? 1 : 0), native elements \(inspector.native.path.count)")
        }
    }

    @Test func pickingOutlinesNativeObjectsAndTakesTheClick() {
        withInspectorOn {
            let (window, row, tab, pane) = Self.nativeWindow()
            defer { window.close() }
            let inspector = inspector(for: window)
            inspector.toggle()
            defer { if inspector.isPicking { inspector.toggle() } }

            let overRow = window.convertPoint(toScreen: NSPoint(x: row.frame.midX, y: row.frame.midY))
            let move = mouse(.mouseMoved, at: overRow, in: window)
            #expect(inspector.handle(move, window: window, point: overRow) === move, "a move must go on")
            #expect(inspector.native.current?.kind == .workspace)
            #expect(inspector.native.current?.title == "api")
            #expect(inspector.native.isShowing)

            let overTab = window.convertPoint(toScreen: NSPoint(x: tab.midX, y: tab.midY))
            _ = inspector.handle(mouse(.mouseMoved, at: overTab, in: window), window: window, point: overTab)
            #expect(inspector.native.current?.kind == .tab)
            #expect(inspector.native.current?.identifier == "cmux.tabs.tab.t1")
            #expect(inspector.native.path.map(\.kind) == [.tab, .tabStrip])

            let inPane = window.convertPoint(toScreen: NSPoint(x: pane.frame.midX, y: pane.frame.midY))
            _ = inspector.handle(mouse(.mouseMoved, at: inPane, in: window), window: window, point: inPane)
            #expect(inspector.native.current?.kind == .pane, "a pane's unnamed insides name the pane")
            let report = inspector.native.current?.report(path: inspector.native.path) ?? ""
            #expect(report.contains("cmux.layout.pane.p1"))

            let click = mouse(.leftMouseDown, at: inPane, in: window)
            #expect(inspector.handle(click, window: window, point: inPane) == nil, "the picker let a native click through")
            let release = mouse(.leftMouseUp, at: inPane, in: window)
            #expect(inspector.handle(release, window: window, point: inPane) == nil, "the picked press's release reached the view")
            #expect(inspector.handle(move, window: window, point: overRow) === move)
            #expect(!inspector.native.isShowing, "a move during the capture outlined again")
            #expect(!inspector.native.isShowing, "the outline stayed up for the capture")
        }
    }

    @Test func stopDropsEverything() {
        withInspectorOn {
            let (window, row, _, _) = Self.nativeWindow()
            defer { window.close() }
            let inspector = inspector(for: window)
            inspector.toggle()
            let point = window.convertPoint(toScreen: NSPoint(x: row.frame.midX, y: row.frame.midY))
            _ = inspector.handle(mouse(.mouseMoved, at: point, in: window), window: window, point: point)
            #expect(inspector.native.isShowing)
            inspector.toggle()
            #expect(!inspector.isPicking && !inspector.native.isShowing && inspector.native.current == nil)
        }
    }

    @Test func aNativeMenuStartsOnItsObject() {
        withInspectorOn {
            let (window, _, _, _) = Self.nativeWindow()
            defer { window.close() }
            let inspector = inspector(for: window)
            defer { if inspector.isPicking { inspector.toggle() } }
            inspector.inspectFromContextMenu(menu: .tab, target: ActionTargetRef(kind: .tab, id: "t1"))
            #expect(inspector.isPicking)
            #expect(inspector.native.current?.identifier == "cmux.tabs.tab.t1")
            inspector.toggle()
            inspector.inspectFromContextMenu(menu: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: "w1"))
            #expect(inspector.native.current?.kind == .workspace)
            inspector.toggle()
            inspector.inspectFromContextMenu(menu: .pane, target: ActionTargetRef(kind: .pane, id: "p1"))
            #expect(inspector.native.current?.kind == .pane)
            // Up walks out, Down back in.
            #expect(inspector.native.key(125) == .handled)
            #expect(inspector.native.key(53) == .pass)
            inspector.toggle()
            // A tab in another pane's list (here a vertical one) is found too.
            let list = Strip(frame: NSRect(x: 230, y: 300, width: 160, height: 200))
            list.setAccessibilityRole(.tabGroup)
            let row = NSAccessibilityElement()
            row.setAccessibilityIdentifier("cmux.tabs.vertical.t2")
            row.setAccessibilityLabel("build.log")
            row.setAccessibilityFrame(window.convertToScreen(NSRect(x: 230, y: 470, width: 160, height: 26)))
            list.tabs = [row]
            window.contentView?.subviews.first { $0.accessibilityIdentifier() == "cmux.layout.pane.p1" }?.addSubview(list)
            inspector.inspectFromContextMenu(menu: .tab, target: ActionTargetRef(kind: .tab, id: "t2"))
            #expect(inspector.native.current?.kind == .tab)
            #expect(inspector.native.current?.title == "build.log")
        }
    }

    @Test func aRowsOwnButtonIsAControl() {
        withInspectorOn {
            let (window, row, _, _) = Self.nativeWindow()
            defer { window.close() }
            let close = NSButton(title: "Close", target: nil, action: nil)
            close.frame = NSRect(x: row.frame.maxX - 24, y: row.frame.minY + 4, width: 20, height: 20)
            close.setAccessibilityIdentifier("cmux.sidebar.workspace.w1.close")
            window.contentView?.addSubview(close)
            let found = UIPointerNativeElement.elements(at: NSPoint(x: close.frame.midX, y: close.frame.midY), in: window)
            #expect(found.first?.kind == .control)
        }
    }

    /// A real sidebar row answers no hit-test over its body (`SidebarRowView.hitTest`: the list owns the click), so
    /// the hit lands on the list; the row under the pointer is still the one picked.
    @Test func aRowThatDeclinesTheHitIsStillPicked() {
        withInspectorOn {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let list = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
            window.contentView?.addSubview(list)
            for (index, id) in ["w1", "w2"].enumerated() {
                let row = DecliningRow(frame: NSRect(x: 8, y: 240 - CGFloat(index) * 32, width: 200, height: 28))
                row.setAccessibilityIdentifier("cmux.sidebar.workspace.\(id)")
                row.setAccessibilityLabel(id == "w1" ? "api" : "web")
                list.addSubview(row)
            }
            let found = UIPointerNativeElement.elements(at: NSPoint(x: 100, y: 222), in: window)
            #expect(found.first?.kind == .workspace)
            #expect(found.first?.identifier == "cmux.sidebar.workspace.w2")
        }
    }

    @Test func movesOverDeepNativeUIAreCheap() {
        withInspectorOn {
            let (window, point) = deepNativeWindow()
            defer { window.close() }
            let inspector = inspector(for: window)
            inspector.toggle()
            defer { if inspector.isPicking { inspector.toggle() } }
            let move = mouse(.mouseMoved, at: point, in: window)
            #expect(inspector.handle(move, window: window, point: point) === move)

            let moves = 5_000
            let clock = ContinuousClock()
            // The same loop as before native picking came back: one point, repeated.
            let same = clock.measure { for _ in 0..<moves { _ = inspector.handle(move, window: window, point: point) } }
            // Every move at a new point: a hit-test and a walk up each time.
            let other = NSPoint(x: point.x + 1, y: point.y)
            let moveOther = mouse(.mouseMoved, at: other, in: window)
            let varying = clock.measure {
                for index in 0..<moves {
                    let odd = index % 2 == 1
                    _ = inspector.handle(odd ? moveOther : move, window: window, point: odd ? other : point)
                }
            }
            for (label, elapsed) in [("", same), (" (each move a new point)", varying)] {
                let nanos = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
                print(String(format: "INSPECT-BENCH native mouseMoved while picking%@: %d moves, %.2f us/move, %.1f ms total",
                             label, moves, nanos / Double(moves) / 1000, nanos / 1e6))
            }
            #expect(!inspector.native.isShowing, "unnamed native views drew an outline")
        }
    }
}

/// A view like `SidebarRowView`: no hit over its body.
private final class DecliningRow: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
