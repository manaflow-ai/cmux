import CmuxNextDaemon
import Foundation

/// `system.*` and `window.*`. Windows are frontend-local; every window's
/// sidebar lists every workspace, so a window "contains" all of them.
enum CompatSystemMethods {
    static let table: [String: CompatHandler] = [
        "system.ping": .read({ _ in ["pong": true] }),
        "system.capabilities": .read(capabilities),
        "system.identify": .async(identify),
        "system.tree": .async(tree),
        "window.list": .read({ call in
            let world = try call.snapshotWorld()
            return ["windows": .array(world.windows.map { .object(CompatJSON.window($0, in: world)) })]
        }),
        "window.current": .read({ call in
            let world = try call.snapshotWorld()
            guard let window = try call.target(world).window() else { throw CompatErrors.notFound("window", "current") }
            return .object(CompatJSON.ids(window: window, include: ["window"]))
        }),
        "window.create": .async({ call in try await newWindow(call) }),
        "window.focus": .async({ call in try await windowIntent(call) { .focusWindow(windowID: $0.modelID) } }),
        "window.close": .async({ call in try await windowIntent(call) { .closeWindow(windowID: $0.modelID) } }),
    ]

    static func capabilities(_ call: CompatCall) throws -> JSON {
        let transport = call.service.router?.transportInfo
        return [
            "protocol": "cmux-socket", "version": 2,
            "socket_path": transport?.socketPath.map(JSON.string) ?? .null,
            "access_mode": transport?.accessMode.map(JSON.string) ?? .null,
            "capabilities": ["cmux-next", "daemon-forwarding"],
            "methods": .array((call.service.router?.methodNames ?? []).sorted().map(JSON.string)),
            "unsupported_namespaces": .array(CompatUnsupported.namespaces.keys.sorted().map(JSON.string)),
        ]
    }

    static func identify(_ call: CompatCall) async throws -> JSON {
        let service = call.service
        var result: [String: JSON] = [
            "socket_path": service.router?.transportInfo.socketPath.map(JSON.string) ?? .null,
            "bundle_identifier": service.identity.bundleID.map(JSON.string) ?? .null,
            "app_bundle_path": .string(Bundle.main.bundlePath),
            "app_executable_path": Bundle.main.executablePath.map(JSON.string) ?? .null,
            "app_cli_path": Bundle.main.url(forResource: "cmux", withExtension: nil, subdirectory: "bin").map { .string($0.path) } ?? .null,
            "app": .string(service.identity.appName), "version": .string(service.identity.version),
            "tag": service.identity.tag.map(JSON.string) ?? .null, "pid": JSON(Int(service.identity.processID)),
            "focused": .null, "caller": .null,
        ]
        guard let world = try? await call.world() else { return .object(result) }
        let target = call.target(world)
        let window = try? target.window()
        if let workspace = world.currentWorkspace(window: window) {
            let focus = world.focus(in: workspace)
            result["focused"] = CompatJSON.focusObject(window: window, workspace: workspace, pane: focus.pane, surface: focus.surface)
        } else if let window {
            result["focused"] = .object(CompatJSON.ids(window: window, include: ["window"]))
        }
        if let caller = call.params["caller"]?.objectValue {
            result["caller"] = callerObject(caller, world: world, refs: service.refs)
        }
        return .object(result)
    }

    static func callerObject(_ caller: [String: JSON], world: CompatWorld, refs: CompatRefRegistry) -> JSON {
        let target = CompatTarget(world: world, refs: refs, params: caller)
        guard let workspace = try? target.workspace() else { return .null }
        var surface: CompatWorld.Surface?
        if let raw = target.string("surface_id") ?? target.string("tab_id") {
            guard let found = try? world.resolveSurface(raw, in: workspace, refs: refs), found.workspaceUUID == workspace.uuid else { return .null }
            surface = found
        }
        let pane = surface.flatMap { world.panes[$0.paneUUID] }
        let window = world.window(workspace.windowUUIDs.first) ?? world.activeWindow
        return CompatJSON.focusObject(window: window, workspace: workspace, pane: pane, surface: surface)
    }

    static func tree(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let target = call.target(world)
        if call.params["window_id"] != nil, call.bool("all_windows") == true {
            throw CompatErrors.invalid("window_id and all_windows are mutually exclusive")
        }
        let onlyWorkspace = try target.string("workspace_id").map { try world.resolveWorkspace($0, refs: call.service.refs) }
        let active = try target.window()
        let windows = call.bool("all_windows") == true ? world.windows : active.map { [$0] } ?? []
        func workspaceItem(_ workspace: CompatWorld.Workspace, window: CompatWorld.Window?) -> JSON {
            var item = CompatJSON.workspace(workspace, selected: window?.workspaceUUID == workspace.uuid, in: world)
            item["panes"] = .array(world.orderedPanes(in: workspace).map { pane in
                var paneItem = CompatJSON.pane(pane, in: world)
                paneItem["surfaces"] = .array(world.orderedSurfaces(in: pane).map { .object(CompatJSON.surface($0, in: world)) })
                return .object(paneItem)
            })
            return .object(item)
        }
        let scoped = world.workspaces.filter { onlyWorkspace == nil || $0.uuid == onlyWorkspace?.uuid }
        var windowItems: [JSON] = windows.map { window in
            var item = CompatJSON.window(window, in: world)
            item["workspaces"] = .array(scoped.map { workspaceItem($0, window: window) })
            return .object(item)
        }
        if windowItems.isEmpty {
            windowItems = [["id": .null, "ref": .null, "index": 0, "key": false, "visible": false,
                            "workspace_count": JSON(world.workspaces.count),
                            "workspaces": .array(scoped.map { workspaceItem($0, window: nil) })]]
        }
        var activeFocus: JSON = .null
        if let workspace = world.currentWorkspace(window: active) {
            let focus = world.focus(in: workspace)
            activeFocus = CompatJSON.focusObject(window: active, workspace: workspace, pane: focus.pane, surface: focus.surface)
        }
        let caller = call.params["caller"]?.objectValue.map { callerObject($0, world: world, refs: call.service.refs) } ?? .null
        return ["active": activeFocus, "caller": caller, "windows": .array(windowItems)]
    }

    static func newWindow(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let workspace = try? call.target(world).workspace()
        let result = try await call.perform(.newWindow(workspaceID: workspace?.modelID))
        let after = try await call.world()
        let window = result["window_id"]?.stringValue.flatMap { id in after.windows.first { $0.modelID == id } }
        return .object(CompatJSON.ids(window: window, include: ["window"]))
    }

    static func windowIntent(_ call: CompatCall, _ make: (CompatWorld.Window) -> CompatFrontendIntent) async throws -> JSON {
        let world = try await call.world()
        guard let raw = call.string("window_id") else { throw CompatErrors.missing("window_id", call.method) }
        let window = try world.resolveWindow(raw, refs: call.service.refs)
        try await call.perform(make(window))
        return .object(CompatJSON.ids(window: window, include: ["window"]))
    }
}
