import CmuxNextDaemon
import Foundation
import Synchronization

/// A scripted v1 daemon that keeps a workspace tree and changes it like
/// cmux-tui for the creating commands App tests run (`new-tab`, `split`,
/// `create-workspace`, `create-terminal`, `move-tab-to-new-workspace`,
/// `rename-workspace`).
/// `list-workspaces` reports the current tree, so `DaemonService.reconcile`
/// mirrors what a command made. It starts with one workspace whose one pane
/// holds two tabs.
nonisolated final class TopologyDaemon: Sendable {
    static let firstKey = "2a4f6c1e-8b3d-4e5f-9a7b-1c2d3e4f5a01"

    struct Pane: Sendable {
        var id: Int
        var tabs: [Int]
    }

    indirect enum Layout: Sendable {
        case leaf(Int)
        case split(String, Layout, Layout)

        func replacing(_ pane: Int, with node: Layout) -> Layout {
            switch self {
            case .leaf(let id): id == pane ? node : self
            case .split(let dir, let a, let b): .split(dir, a.replacing(pane, with: node), b.replacing(pane, with: node))
            }
        }

        var json: String {
            switch self {
            case .leaf(let id): #"{"type":"leaf","pane":\#(id)}"#
            case .split(let dir, let a, let b): #"{"type":"split","dir":"\#(dir)","ratio":0.5,"a":\#(a.json),"b":\#(b.json)}"#
            }
        }
    }

    struct Screen: Sendable {
        var id: Int
        var layout: Layout
        var panes: [Pane]
    }

    struct Workspace: Sendable {
        var id: Int
        var key: String
        var screens: [Screen]
        var name: String? = nil
        /// `workspace-kind-v1`: `home` for the store's home workspace.
        var kind: String? = nil
    }

    struct Tree: Sendable {
        var workspaces: [Workspace]
        var nextID = 100
        var revision = 1

        mutating func next() -> Int {
            nextID += 1
            return nextID
        }

        var json: String {
            let workspaces = workspaces.map { workspace in
                let screens = workspace.screens.map { screen in
                    let panes = screen.panes.map { pane in
                        let tabs = pane.tabs.map { #"{"surface":\#($0),"kind":"pty","title":"t\#($0)"}"# }.joined(separator: ",")
                        return #"{"id":\#(pane.id),"active_tab":0,"tabs":[\#(tabs)]}"#
                    }.joined(separator: ",")
                    return #"{"id":\#(screen.id),"layout":\#(screen.layout.json),"panes":[\#(panes)]}"#
                }.joined(separator: ",")
                let kind = workspace.kind.map { #","kind":"\#($0)""# } ?? ""
                return #"{"id":\#(workspace.id),"key":"\#(workspace.key)","name":"\#(workspace.name ?? "w\(workspace.id)")"\#(kind),"screens":[\#(screens)]}"#
            }.joined(separator: ",")
            return #"{"generation":"g1","registry_id":"r","workspace_revision":\#(revision),"workspaces":[\#(workspaces)]}"#
        }

        func locate(pane: Int) -> (Int, Int, Int)? {
            for (w, workspace) in workspaces.enumerated() {
                for (s, screen) in workspace.screens.enumerated() {
                    if let p = screen.panes.firstIndex(where: { $0.id == pane }) { return (w, s, p) }
                }
            }
            return nil
        }

        func locate(surface: Int) -> (Int, Int, Int)? {
            for (w, workspace) in workspaces.enumerated() {
                for (s, screen) in workspace.screens.enumerated() {
                    if let p = screen.panes.firstIndex(where: { $0.tabs.contains(surface) }) { return (w, s, p) }
                }
            }
            return nil
        }
    }

    final class State: Sendable {
        let tree = Mutex(Tree(workspaces: [Workspace(id: 1, key: firstKey, screens: [
            Screen(id: 2, layout: .leaf(3), panes: [Pane(id: 3, tabs: [11, 12])]),
        ])]))
    }

    let state = State()
    let socket: ScriptedDaemonSocket
    final class CommandLog: Sendable {
        let names = Mutex<[String]>([])
    }

    /// Every command name the app sent, in order.
    let commands = CommandLog()

    /// `extraCapabilities` are advertised besides the required ones.
    init(extraCapabilities: [String] = []) throws {
        let state = state, commands = commands
        socket = try ScriptedDaemonSocket(handler: { request in
            let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
            func ok(_ data: String) -> [String] { [#"{"id":\#(id),"ok":true,"data":\#(data)}"#] }
            func int(_ name: String) -> Int { request[name]?.doubleValue.map { Int($0) } ?? 0 }
            commands.names.withLock { $0.append(request["cmd"]?.stringValue ?? "") }
            switch request["cmd"]?.stringValue {
            case "identify":
                let caps = (DaemonCapabilities.shared.required + extraCapabilities).map { "\"\($0)\"" }.joined(separator: ",")
                let revision = state.tree.withLock { $0.revision }
                return ok(#"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"r","generation":"g1","workspace_revision":\#(revision)}"#)
            case "list-workspaces":
                return ok(state.tree.withLock { $0.json })
            case "list-agents":
                // A resync after `connected` seeds agents; `{}` would fail it
                // and leave `refresh()` waiting on retries.
                return ok(#"{"agents":[]}"#)
            case "new-tab":
                let surface = state.tree.withLock { tree -> Int in
                    let surface = tree.next()
                    if let (w, s, p) = tree.locate(pane: int("pane")) { tree.workspaces[w].screens[s].panes[p].tabs.append(surface) }
                    tree.revision += 1
                    return surface
                }
                return ok(#"{"surface":\#(surface)}"#)
            case "split":
                let surface = state.tree.withLock { tree -> Int in
                    let pane = int("pane"), newPane = tree.next(), surface = tree.next()
                    if let (w, s, _) = tree.locate(pane: pane) {
                        let screen = tree.workspaces[w].screens[s]
                        tree.workspaces[w].screens[s].layout = screen.layout.replacing(pane, with: .split(request["dir"]?.stringValue ?? "right", .leaf(pane), .leaf(newPane)))
                        tree.workspaces[w].screens[s].panes.append(Pane(id: newPane, tabs: [surface]))
                    }
                    tree.revision += 1
                    return surface
                }
                return ok(#"{"surface":\#(surface)}"#)
            case "create-workspace":
                let key = request["key"]?.stringValue ?? UUID().uuidString.lowercased()
                let (workspace, revision) = state.tree.withLock { tree -> (Int, Int) in
                    let workspace = tree.next()
                    tree.workspaces.append(Workspace(id: workspace, key: key, screens: []))
                    tree.revision += 1
                    return (workspace, tree.revision)
                }
                return ok(#"{"workspace":\#(workspace),"key":"\#(key)","workspace_revision":\#(revision),"replayed":false}"#)
            case "create-terminal":
                let key = request["key"]?.stringValue ?? ""
                let created = state.tree.withLock { tree -> (surface: Int, pane: Int, screen: Int, workspace: Int)? in
                    guard let w = tree.workspaces.firstIndex(where: { $0.key == key }) else { return nil }
                    let screen = tree.next(), pane = tree.next(), surface = tree.next()
                    tree.workspaces[w].screens.append(Screen(id: screen, layout: .leaf(pane), panes: [Pane(id: pane, tabs: [surface])]))
                    tree.revision += 1
                    return (surface, pane, screen, tree.workspaces[w].id)
                }
                guard let created else { return [#"{"id":\#(id),"ok":false,"error":"no such workspace"}"#] }
                return ok(#"{"surface":\#(created.surface),"terminal_id":"\#(UUID().uuidString.lowercased())","pane":\#(created.pane),"screen":\#(created.screen),"workspace":\#(created.workspace),"key":"\#(key)","lifecycle":"running","replayed":false}"#)
            case "move-tab-to-new-workspace":
                let surface = int("surface")
                let key = UUID().uuidString.lowercased()
                let moved = state.tree.withLock { tree -> Int? in
                    guard let (w, s, p) = tree.locate(surface: surface) else { return nil }
                    tree.workspaces[w].screens[s].panes[p].tabs.removeAll { $0 == surface }
                    let workspace = tree.next(), screen = tree.next(), pane = tree.next()
                    tree.workspaces.append(Workspace(id: workspace, key: key, screens: [
                        Screen(id: screen, layout: .leaf(pane), panes: [Pane(id: pane, tabs: [surface])]),
                    ], name: request["name"]?.stringValue))
                    tree.revision += 1
                    return workspace
                }
                guard let moved else { return [#"{"id":\#(id),"ok":false,"error":"no such tab"}"#] }
                return ok(#"{"surface":\#(surface),"workspace":\#(moved),"key":"\#(key)","undoable":false}"#)
            case "rename-workspace":
                let key = request["key"]?.stringValue, name = request["name"]?.stringValue
                let renamed = state.tree.withLock { tree -> (Int, Int)? in
                    guard let w = tree.workspaces.firstIndex(where: { $0.key == key }) else { return nil }
                    tree.workspaces[w].name = name
                    tree.revision += 1
                    return (tree.workspaces[w].id, tree.revision)
                }
                guard let (workspace, revision) = renamed, let key else { return [#"{"id":\#(id),"ok":false,"error":"no such workspace"}"#] }
                return ok(#"{"workspace":\#(workspace),"key":"\#(key)","workspace_revision":\#(revision),"replayed":false}"#)
            default:
                return ok("{}")
            }
        })
    }

    func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: socket.path))
    }

    func stop() { socket.stop() }
}
