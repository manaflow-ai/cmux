@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `cmux tab reload --target surface:2` (and every action verb) takes the
/// refs and UUIDs the old CLI prints. `action.run` resolves them to the
/// App's model ids before the handler runs; before this, the handler got
/// `tab:surface:2` and refused it as "not shown in any window".
@Suite(.timeLimit(.minutes(1))) struct CompatActionTargetTests {
    func install() -> (ControlRouter, CompatService, RecordingExecutor) {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        var snapshot = ControlSnapshot.sample()
        let base = snapshot.catalog
        snapshot.catalog = ControlCatalog(actions: base.actions + [
            Self.action("tabReload", targets: ["tab"]),
            Self.action("paneZoom", targets: ["pane"]),
            Self.action("workspaceRename", targets: ["workspace"]),
            Self.action("windowClose", targets: ["window"]),
        ], aliases: base.aliases, targetKinds: base.targetKinds, debugActionsAvailable: true)
        router.snapshots.publish { $0 = snapshot }
        return (router, service, executor)
    }

    static func action(_ id: String, targets: [String]) -> ControlActionInfo {
        ControlActionInfo(id: id, title: id, category: "tab", categoryTitle: "Tabs", cliName: id, symbol: "circle",
                          keywords: [], shortcut: nil, shortcutConfig: nil, arguments: [], targets: targets,
                          requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil)
    }

    func run(_ router: ControlRouter, _ action: String, _ target: String) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "action.run", params: ["action": .string(action), "target": .string(target)]))
    }

    /// The refs a script got from `list-panels` / `tree` (minted per process).
    func refs(_ router: ControlRouter, _ service: CompatService) -> CompatWorld {
        CompatWorld(topology: router.snapshots.current.topology, refs: service.refs)
    }

    @Test func surfaceRefsResolveToTheTabModelID() async throws {
        let (router, service, executor) = install()
        let world = refs(router, service)
        let surface = try #require(world.surfaces.values.first)
        _ = try await run(router, "tabReload", surface.ref).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-1"))
        // The old CLI shows surface:N as tab:N; both name the same tab.
        let number = surface.ref.split(separator: ":").last.map(String.init) ?? ""
        _ = try await run(router, "tabReload", "tab:\(number)").get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-1"))
        _ = try await run(router, "tabReload", surface.uuid).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-1"))
    }

    @Test func paneWorkspaceAndWindowRefsResolve() async throws {
        let (router, service, executor) = install()
        let world = refs(router, service)
        let pane = try #require(world.panes.values.first)
        let surface = try #require(world.surfaces.values.first)
        _ = try await run(router, "paneZoom", pane.ref).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "pane", id: "pane-1"))
        // A surface ref names its pane for a pane action.
        _ = try await run(router, "paneZoom", surface.ref).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "pane", id: "pane-1"))
        let workspace = try #require(world.workspaces.first)
        _ = try await run(router, "workspaceRename", workspace.ref).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "workspace", id: "ws-1"))
        let window = try #require(world.windows.first)
        _ = try await run(router, "windowClose", window.ref).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "window", id: "win-1"))
    }

    @Test func nativeIDsPassThroughAndUnknownRefsFail() async throws {
        let (router, _, executor) = install()
        _ = try await run(router, "tabReload", "tab:tab-1").get()
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-1"))
        let before = executor.requests.withLock { $0.count }
        guard case .failure(let error) = await run(router, "tabReload", "surface:999") else {
            Issue.record("an unknown ref must fail")
            return
        }
        #expect(error.code == "not_found", "\(error)")
        #expect(executor.requests.withLock { $0.count } == before)
    }
}
