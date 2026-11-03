import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// The STRESS builder (scripts/cmux-next/perf-stress-session.py `focus_pane`) moves the focus with
/// `action.run pane.focus target=pane:<id> origin=script focus=true` and waits for the control
/// snapshot's window to name that pane. On the fleet (e7a0de6d717, bb1dc8698bf, macOS 27) the run
/// answered `ran`, the window's focus machine and layout named the pane, and `snapshot.get` kept
/// the old pane for 10 s: "focus never reached pane". A script's focus with `focus: true` moves the
/// focused pane, and the snapshot a reader gets afterwards says so (or the run refuses: never a
/// silent success).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ScriptPaneFocusTests {
    /// Runs each frame's work on the next main-actor turn (no display link in a test process).
    struct SoonFrames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }

    private static func until(_ condition: () async throws -> Bool, within timeout: Duration = .seconds(20),
                              report: () async throws -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        // A test wait for the app to settle (a daemon reply, a frame): the condition is read again each turn.
        while !(try await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let met = try await condition()
        let detail = met ? "" : try await report()
        try #require(met, "timed out: \(detail)", sourceLocation: sourceLocation)
    }

    @Test func aScriptsPaneFocusWithFocusMovesTheFocusedPaneInTheSnapshot() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let bridge = RegistryControlBridge(registry: services.registry)
            let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: getpid()),
                                       executor: bridge, configuration: .init(requestDeadline: .seconds(30)), frameSource: SoonFrames())
            // The app's wiring: the bridge publishes the action catalog and the registry's context mask.
            bridge.attach(to: router)
            let publisher = ControlSnapshotPublisher(router: router, services: services, frames: SoonFrames())
            publisher.start()
            defer { publisher.stop() }
            @MainActor func call(_ method: String, _ params: [String: CmuxNextSettings.JSONValue] = [:]) async throws -> CmuxNextSettings.JSONValue {
                try await router.handle(ControlRequest(id: "1", method: method, params: params)).get()
            }
            @MainActor func topology() async throws -> [String: CmuxNextSettings.JSONValue] {
                try await call("snapshot.get").objectValue?["topology"]?.objectValue ?? [:]
            }
            @MainActor func shownWindow() async throws -> [String: CmuxNextSettings.JSONValue]? {
                try await topology()["windows"]?.arrayValue?.compactMap(\.objectValue).first { $0["key"] == .string(window.state.id) }
            }
            @MainActor func snapshotFocusedPane() async throws -> String? { try await shownWindow()?["focused_pane"]?.stringValue }
            /// The shown workspace's panes by public id, as the STRESS builder reads them (no dock panes).
            @MainActor func snapshotPanes() async throws -> [String] {
                let shown = try await shownWindow()?["workspace"]
                let workspace = try await topology()["workspaces"]?.arrayValue?.compactMap(\.objectValue).first { $0["id"] == shown }
                return (workspace?["screens"]?.arrayValue ?? []).flatMap { $0.objectValue?["panes"]?.arrayValue ?? [] }
                    .compactMap(\.objectValue).filter { $0["dock"]?.boolValue != true }.compactMap { $0["id"]?.stringValue }
            }

            // A workspace of two panes, as the daemon and the snapshot list them.
            try await PasswordManagerRouteTests.until({ window.focusedPane != nil },
                                                       report: { "page \(String(describing: window.state.page))" })
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await Self.until({ try await snapshotPanes().count == 2 }, report: { "snapshot panes \(try await snapshotPanes())" })
            let panes = try await snapshotPanes()
            // The person focuses the first pane.
            #expect(services.registry.perform("pane.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: panes[0]), origin: .user)))
            try await Self.until({ try await snapshotFocusedPane() == panes[0] },
                                 report: { "snapshot focused \(String(describing: try await snapshotFocusedPane())), panes \(panes)" })

            // A second tab in the first pane, as STRESS's first pane holds six: the actions' reasons differ
            // between the panes (Close Other Tabs), so the bridge publishes the catalog after the focus moves.
            @MainActor func tabCount(_ pane: String) async throws -> Int {
                let shown = try await shownWindow()?["workspace"]
                let workspace = try await topology()["workspaces"]?.arrayValue?.compactMap(\.objectValue).first { $0["id"] == shown }
                let entry = (workspace?["screens"]?.arrayValue ?? []).flatMap { $0.objectValue?["panes"]?.arrayValue ?? [] }
                    .compactMap(\.objectValue).first { $0["id"] == .string(pane) }
                return entry?["tabs"]?.arrayValue?.count ?? 0
            }
            #expect(services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)))
            try await Self.until({ try await tabCount(panes[0]) == 2 }, report: { "first pane tabs \(try await tabCount(panes[0]))" })
            try #require(try await snapshotFocusedPane() == panes[0])

            // The script's run, as the STRESS builder sends it.
            let reply = try await call("action.run", [
                "action": "pane.focus", "target": .string("pane:\(panes[1])"), "args": [:], "focus": true, "origin": "script",
            ])
            #expect(reply.objectValue?["ran"] == .bool(true), "\(reply)")
            try await Self.until({ try await snapshotFocusedPane() == panes[1] }, within: .seconds(10), report: {
                "snapshot focused \(String(describing: try await snapshotFocusedPane())), machine \(window.focus.state.pane ?? "nil"), "
                    + "controller \(window.focusedPane?.pane.id ?? "nil"), stale \(router.snapshots.isStale)"
            })
        }
    }
}
