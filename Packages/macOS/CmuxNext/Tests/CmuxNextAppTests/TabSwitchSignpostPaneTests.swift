import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextFocusUI
@testable import CmuxNextSignposts
@testable import CmuxNextTabs
@testable import CmuxNextTrace
import Foundation
import QuartzCore
import Testing

/// `switch.tab` through a real pane (p09-observability task 028): `PaneController.select` begins one pair with the
/// destination's kind, the pane's show of that destination (`showSelected`) ends it at the commit boundary, and a
/// re-show of the tab already shown ends nothing. A run that may not change the view, or a suspended pane, begins
/// nothing; a pane suspended before its cold content showed ends its switch as missed, never as committed after
/// the hidden time.
@MainActor @Suite(.serialized)
struct TabSwitchSignpostPaneTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "tab-switch-signpost")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView {
            NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        }
    }

    /// The `switch.tab` records a test runtime writes.
    private final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])
        var records: [TraceRuntime.StubRecord] {
            state.withLock { $0 }.filter { $0.name == SignpostName.switchTab.rawValue }
        }

        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(1 << UInt64(SignpostCategory.switch.traceBit))
            return runtime
        }

        /// Each begin's kind and its end's code (nil while open), matched by async id.
        var pairs: [(kind: UInt64, end: UInt64?)] {
            var result: [(id: UInt64, kind: UInt64, end: UInt64?)] = []
            for record in records {
                switch record.phase {
                case .asyncBegin: result.append((record.arg1, record.arg0 & 0xFF, nil))
                case .asyncEnd:
                    if let index = result.firstIndex(where: { $0.id == record.arg1 && $0.end == nil }) {
                        result[index].end = record.arg0 & 0xFF
                    } else {
                        Issue.record("a switch.tab end without its begin")
                    }
                default: Issue.record("switch.tab wrote phase \(record.phase)")
                }
            }
            return result.map { ($0.kind, $0.end) }
        }
    }

    /// Commit boundaries asked for and not fired yet.
    @MainActor
    private final class Boundaries {
        var waiting: [@MainActor (CommitBoundary.Outcome) -> Void] = []
        func fire() {
            let due = waiting
            waiting = []
            for body in due { body(.committed) }
        }
    }

    private struct Rig {
        let services: AppServices
        let pane: PaneController
        /// The pane's window state: the pane holds it weakly, as its window controller owns it in the app.
        let state: WindowState
        let window: NSWindow
        /// Two page tabs shown once (warm), the second selected, and a third never shown (cold).
        let warm: [String]
        let cold: String

        func tearDown() {
            pane.teardown()
            window.close()
        }
    }

    private let log = RecordLog()
    private let boundaries = Boundaries()

    private func rig() throws -> Rig {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let boundaries = boundaries
        services.tabSwitch = TabSwitchSignpost(signposter: Signposter(category: .switch, trace: log.runtime())) {
            boundaries.waiting.append($0)
        }
        let store = services.daemon.store
        let identity = #"{"app":"cmux-tui","protocol":1,"session":"tab-switch-signpost","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(identity.utf8)))
        let paneSnapshot = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [paneSnapshot])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1",
                                                                        screens: [screen])]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let provider = Provider()
        services.pages.register(provider)
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: state)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 340), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        pane.view.frame = NSRect(x: 0, y: 0, width: 400, height: 340)
        window.contentView = pane.view
        let keys = (0..<3).map { _ in services.pages.open(provider.page, in: pane.paneKey, of: store) }
        pane.syncStripFromStore()
        // Shown by the focus applier's call, which begins no switch: only `select` (the intent) does.
        for key in keys.prefix(2) { pane.applySelection(StripTabID(key)); pane.showSelected() }
        #expect(keys.prefix(2).allSatisfy { services.pages.existingView($0) != nil }, "the first two tabs are warm")
        #expect(services.pages.existingView(keys[2]) == nil, "the third tab is cold")
        #expect(log.records.isEmpty)
        return Rig(services: services, pane: pane, state: state, window: window, warm: Array(keys.prefix(2)), cold: keys[2])
    }

    @Test func aWarmAndAColdSwitchAreOnePairEachWithTheirKinds() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        rig.pane.select(StripTabID(rig.warm[0]))
        #expect(boundaries.waiting.count == 1, "a warm destination shows in the intent's turn")
        boundaries.fire()
        // The tab already shown is shown again (a store change): nothing ends, nothing begins.
        rig.pane.showSelected()
        #expect(boundaries.waiting.isEmpty)

        rig.pane.select(StripTabID(rig.cold))
        #expect(boundaries.waiting.isEmpty, "a cold destination shows on a later frame")
        rig.pane.showSelected()
        boundaries.fire()
        let pairs = log.pairs
        try #require(pairs.count == 2)
        #expect(pairs[0].kind == TabSwitchSignpost.Kind.warm.rawValue && pairs[0].end == Signposter.EndCode.ended)
        #expect(pairs[1].kind == TabSwitchSignpost.Kind.cold.rawValue && pairs[1].end == Signposter.EndCode.ended)
        #expect(rig.services.tabSwitch.openCount == 0)
    }

    @Test func aRunThatMayNotChangeTheViewBeginsNoSwitch() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            rig.pane.select(StripTabID(rig.warm[0]))
        }
        rig.pane.showSelected()
        boundaries.fire()
        #expect(log.records.isEmpty)
    }

    @Test func aSuspendedPaneBeginsNoSwitchAndItsResumeEndsNone() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        rig.pane.suspend()
        rig.pane.select(StripTabID(rig.warm[0]))
        rig.pane.resume()
        rig.pane.showSelected()
        boundaries.fire()
        #expect(log.records.isEmpty)
    }

    @Test func aPaneSuspendedBeforeItsColdContentShowedEndsTheSwitchAsMissed() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        rig.pane.select(StripTabID(rig.cold))
        rig.pane.suspend()
        rig.pane.resume()
        rig.pane.showSelected()
        boundaries.fire()
        let pairs = log.pairs
        #expect(pairs.count == 1)
        #expect(pairs.first?.end == Signposter.EndCode.missed, "not a committed sample spanning the hidden time")
    }

    // MARK: Input age (begin arg0's top 24 bits, µs; all ones without an input)

    private static let noInput: UInt64 = 0xFF_FFFF

    private func clickEvent(agedSeconds age: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: CACurrentMediaTime() - age,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private var beginAges: [UInt64] { log.records.filter { $0.phase == .asyncBegin }.map { $0.arg0 >> 40 } }

    /// A click on a tab is being dispatched when its switch begins: that click's age is the switch's input stage,
    /// read from the app's input dispatch (`InputDispatchContext`), not from `NSApp.currentEvent`.
    @Test func theClickBeingDispatchedIsTheSwitchInput() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let click = try clickEvent(agedSeconds: 0.003)
        rig.services.inputDispatch.dispatching(click) { rig.pane.select(StripTabID(rig.warm[0])) }
        let ages = beginAges
        try #require(ages.count == 1)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the click 3 ms old: \(ages[0]) µs (all ones: no input stage)")
    }

    /// A socket or CLI `tab.focus` a moment after a click: `NSApp.currentEvent` still holds the click, but no input is
    /// being dispatched and no person's run is in progress, so the switch has no input age.
    @Test func aRecentClickLeftInCurrentEventIsNoSwitchInput() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let stale = try clickEvent(agedSeconds: 0.003)
        try #require(class_getInstanceVariable(NSApplication.self, "_currentEvent") != nil, "NSApplication has no _currentEvent ivar on this macOS")
        NSApp.setValue(stale, forKey: "currentEvent")
        defer { NSApp.setValue(nil, forKey: "currentEvent") }
        try #require(NSApp.currentEvent?.type == .leftMouseDown, "the test could not leave a recent click in currentEvent")
        rig.pane.select(StripTabID(rig.warm[0]))
        #expect(beginAges == [Self.noInput], "a socket switch took the last click's age: \(beginAges)")
    }

    /// The New Tab page's location bar picks a tab: the page's click comes back with its request a turn after its own
    /// dispatch (`InputDispatchContext.answering`), and the switch takes that click's age.
    @Test func aPageClickCarriedWithItsRequestIsTheSwitchInput() throws {
        let rig = try rig()
        defer { rig.tearDown() }
        rig.services.inputDispatch.answering(input: CACurrentMediaTime() - 0.003) { rig.pane.select(StripTabID(rig.warm[0])) }
        let ages = beginAges
        try #require(ages.count == 1)
        #expect(ages[0] >= 3_000 && ages[0] < 1_000_000, "the page's click 3 ms old: \(ages[0]) µs")
    }
}
