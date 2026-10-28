#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextInputModel
import CmuxNextOracle
import Testing

/// The app's `terminals` facet: AppServices lists the local daemon mirror's terminal tabs in the
/// snapshot's main-actor turn and reads their screens off the main actor; a view's attach machine phase maps to the
/// schema's attach states. Run: `swift test --filter AppOracleTerminalsFacetTests`.
@MainActor @Suite(.serialized) struct AppOracleTerminalsFacetTests {
    static let live = "term_" + String(repeating: "a", count: 32)
    static let ended = "term_" + String(repeating: "b", count: 32)
    static let liveTab = "tab_" + String(repeating: "1", count: 32)
    static let endedTab = "tab_" + String(repeating: "2", count: 32)
    static let signaled = "term_" + String(repeating: "d", count: 32)
    static let signaledTab = "tab_" + String(repeating: "3", count: 32)

    @Test func theAttachMachinePhasesMapToTheSchemaStates() {
        typealias Machine = TerminalAttachMachine<Int>
        let pending = Machine.Pending(attempt: 1, failures: 0, size: CellSize(cols: 80, rows: 24), link: nil)
        #expect(Machine.Phase.live(1).oracleAttach == .attached)
        #expect(Machine.Phase.attaching(pending).oracleAttach == .attaching)
        #expect(Machine.Phase.reattaching(pending).oracleAttach == .attaching)
        #expect(Machine.Phase.detached.oracleAttach == .detached)
        #expect(Machine.Phase.disconnected(.init(reason: .streamEnded, failedReconnects: 0)).oracleAttach == .detached)
        #expect(Machine.Phase.closed.oracleAttach == .detached)
        #expect(Machine.Phase.exited.oracleAttach == .dead)
    }

    @Test func theAppListsTheFacetWithItsChangeSignal() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.terminals))
        #expect(facets.signalsChanges(.terminals), "debug.oracle.wait_for can wait on terminals")
        let capture = try facets.beginCapture([.terminals])
        #expect(capture.completed == nil)
        // No machine has a terminal yet.
        let snapshot = try await capture.finish()
        #expect(snapshot["terminals"] == ["list": .array([])] as OracleValue)
    }

    /// A live pty tab, an ended one (exit code 3), a signaled one (no code), a pty tab whose terminal has no public id
    /// yet, a remote-terminal tab and a browser tab: the facet lists the three pty tabs with public ids (the live one
    /// detached, no view made) and leaves the rest out.
    @Test func theFacetListsTheLocalPtyTabsFromTheMirror() async throws {
        let services = seed()
        let terminals = try OracleTerminalsFacet.terminals(in: services.daemon.store.workspaces, attach: { _ in nil }) { surface in
            { "screen \(surface.rawValue)" }
        }
        let facet = OracleTerminalsFacet(rewrite: .init(root: [], home: []), hash: { "hashed(\($0))" }, changes: nil) { terminals }
        let snapshot = try await OracleFacets([facet]).beginCapture([.terminals]).finish()
        let expected: OracleValue = ["list": [
            ["terminal": .string(Self.live), "tab": .string(Self.liveTab), "attach": "detached", "cols": 80, "rows": 24,
             "title": "hashed(zsh)", "cwd": "/work", "last24Sha256": "hashed(screen 1)", "exitCode": nil],
            ["terminal": .string(Self.ended), "tab": .string(Self.endedTab), "attach": "dead", "cols": 0, "rows": 0,
             "title": "hashed()", "cwd": nil, "last24Sha256": "hashed(screen 2)", "exitCode": 3],
            ["terminal": .string(Self.signaled), "tab": .string(Self.signaledTab), "attach": "dead", "cols": 0, "rows": 0,
             "title": "hashed()", "cwd": nil, "last24Sha256": "hashed(screen 3)", "exitCode": nil],
        ]]
        #expect(snapshot["terminals"] == expected)
    }

    /// A pty tab on the local daemon with no connection fails the facet (a broken read is never a value); a remote
    /// machine is not read at all, so it cannot.
    @Test func aPtyTabWithNoLocalConnectionFailsTheRead() throws {
        let services = seed()
        #expect(services.machines.local.connection == nil)
        #expect(throws: OracleFacetError.self) { try services.oracleTerminals() }
    }

    private func seed() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let live = TabSnapshot(surface: 1, tabResourceID: ResourceID(rawValue: Self.liveTab), terminalID: "1",
                               terminalResourceID: ResourceID(rawValue: Self.live), title: "zsh", size: CellSize(cols: 80, rows: 24),
                               cwd: "/work")
        var ended = TabSnapshot(surface: 2, tabResourceID: ResourceID(rawValue: Self.endedTab), terminalID: "2",
                                terminalResourceID: ResourceID(rawValue: Self.ended), dead: true)
        ended.end = TerminalTabEnd(kind: .exited, code: 3)
        var signaled = TabSnapshot(surface: 3, tabResourceID: ResourceID(rawValue: Self.signaledTab), terminalID: "3",
                                   terminalResourceID: ResourceID(rawValue: Self.signaled), dead: true)
        signaled.end = TerminalTabEnd(kind: .signaled, signal: 9)
        var remote = TabSnapshot(surface: 4, terminalResourceID: ResourceID(rawValue: "term_" + String(repeating: "c", count: 32)))
        remote.remote = RemoteTerminalRef(sessionID: "00000000-0000-0000-0000-000000000001", terminalID: "4", sessionName: "other")
        let browser = TabSnapshot(surface: 5, kind: .browser, title: "page", url: "https://example.com")
        let unmade = TabSnapshot(surface: 6, terminalID: "6")
        let pane = PaneSnapshot(id: 1, tabs: [live, ended, signaled, unmade, remote, browser])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return services
    }
}
#endif
