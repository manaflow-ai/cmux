import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// tab-switch-rewrite (u2873): the app's own switch path, a real `PaneController` in a window with N
/// warm page tabs, timed per switch from `applySelection` (the focus applier's call) through the
/// pane's layout, the window's display and the Core Animation commit. Prints
/// `TAB-SWITCH-PATH n=<count> apply p50/p90 <ms> turn p50/p90 <ms> snapshots/switch <x> moves <n>`.
/// The checks are behavioral, at every tab count: a warm switch maps no strip (`structure()`), moves
/// no content view between superviews or windows, and leaves exactly the selected tab's view shown.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .closesItsWindows)
struct TabSwitchPathBench {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "switch-path-bench")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        var made: [MoveCounting] = []
        func makeView(for key: String, in window: WindowController?) -> NSView {
            let view = MoveCounting(frame: NSRect(x: 0, y: 0, width: 900, height: 460))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(calibratedHue: CGFloat(made.count % 10) / 10, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
            made.append(view)
            return view
        }
    }

    /// Counts moves between superviews and windows of the content it stands for.
    final class MoveCounting: NSView {
        var moves = 0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moves += 1 }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); moves += 1 }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"switch-path-bench","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private func finishTurn(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
    }

    @Test(arguments: [2, 10, 30, 60])
    func warmSwitchPath(_ count: Int) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let provider = Provider()
        services.pages.register(provider)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = pane.view
        window.orderFrontRegardless()
        let keys = (0..<count).map { _ in services.pages.open(provider.page, in: pane.paneKey, of: store) }
        pane.syncStripFromStore()
        for key in keys { pane.applySelection(StripTabID(key)); pane.showSelected(); finishTurn(window) }  // warm
        let views = try keys.map { try #require(services.pages.existingView($0)) }
        let probes = provider.made
        let movesBefore = probes.map(\.moves).reduce(0, +)
        let snapshotsBefore = DebugLayoutCounters.paneSnapshots
        var apply: [Double] = [], turn: [Double] = []
        let rounds = max(3, 120 / count)
        var spans: [String: [Double]] = [:]
        for _ in 0..<rounds {
            BenchSpans.begin()
            defer { for span in BenchSpans.end() { spans[span.name, default: []].append(span.milliseconds) } }
            for (index, key) in keys.enumerated() {
                let start = CACurrentMediaTime()
                pane.applySelection(StripTabID(key))
                let applied = CACurrentMediaTime()
                finishTurn(window)
                let end = CACurrentMediaTime()
                apply.append((applied - start) * 1_000)
                turn.append((end - start) * 1_000)
                #expect(views[index].window === window && !views[index].isHidden)
            }
        }
        let switches = apply.count
        let snapshots = Double(DebugLayoutCounters.paneSnapshots - snapshotsBefore) / Double(switches)
        let moves = probes.map(\.moves).reduce(0, +) - movesBefore
        let shown = views.filter { !$0.isHidden && $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }.count
        func q(_ values: [Double], _ p: Double) -> Double { let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
        print(String(format: "TAB-SWITCH-PATH n=%d apply p50 %.3f p90 %.3f max %.3f ms turn p50 %.3f p90 %.3f max %.3f ms snapshots/switch %.2f moves %d switches %d",
                     count, q(apply, 0.5), q(apply, 0.9), apply.max() ?? 0, q(turn, 0.5), q(turn, 0.9), turn.max() ?? 0, snapshots, moves, switches))
        // Where a switch's main-thread time goes, mean µs per switch by stage.
        let stages = spans.map { name, values in (name, values.reduce(0, +) * 1_000 / Double(switches)) }.sorted { $0.1 > $1.1 }
        print("TAB-SWITCH-PATH-STAGES n=\(count) " + stages.map { String(format: "%@=%.1fus", $0.0, $0.1) }.joined(separator: " "))
        #expect(moves == 0, "\(moves) content view moves in \(switches) warm switches over \(count) tabs")
        #expect(shown == 1, "\(shown) tab views shown after the switches (want only the selected one)")
        #expect(snapshots == 0, "a warm switch mapped the strip \(snapshots) times (want 0)")
    }
}
