import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// New Space (`space.new`, the strip's "+") makes a space that starts with
/// its own new workspace, and the window shows that space (cx-d8x5,
/// nxdog77-v1: the new workspace landed in the current space). The home
/// daemon mirrors a new room only after `personal-changed` and a resync,
/// so the create reply comes before the store knows the room; the app must
/// not file the new workspace into a room the store does not hold yet.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SpaceNewEntersOwnWorkspaceTests {
    nonisolated static let session = "r"
    nonisolated static let firstKey = "5b2d7e1c-3f4a-4b6c-8d9e-0a1b2c3d4e51"

    /// A home daemon with rooms (`profiles-v1`): one workspace in `default`,
    /// which follows this session. Rooms and pins change like cmux-tui and
    /// each change sends `personal-changed` before its reply.
    nonisolated final class RoomsDaemon: Sendable {
        struct Workspace: Sendable {
            var id: Int
            var key: String
            var terminal: Bool
        }

        struct State: Sendable {
            var workspaces = [Workspace(id: 1, key: SpaceNewEntersOwnWorkspaceTests.firstKey, terminal: true)]
            var rooms: [(id: String, name: String)] = [("default", "Default")]
            var pins: [(key: String, room: String)] = []
            var revision = 1
            var personalRevision = 1
            var nextID = 100

            var tree: String {
                let workspaces = workspaces.map { workspace in
                    let screens = workspace.terminal
                        ? #"[{"id":\#(workspace.id * 10),"layout":{"type":"leaf","pane":\#(workspace.id * 10 + 1)},"panes":[{"id":\#(workspace.id * 10 + 1),"active_tab":0,"tabs":[{"surface":\#(workspace.id * 10 + 2),"kind":"pty","title":"zsh"}]}]}]"#
                        : "[]"
                    return #"{"id":\#(workspace.id),"key":"\#(workspace.key)","name":"w\#(workspace.id)","screens":\#(screens)}"#
                }.joined(separator: ",")
                return #"{"generation":"g1","registry_id":"\#(SpaceNewEntersOwnWorkspaceTests.session)","workspace_revision":\#(revision),"workspaces":[\#(workspaces)]}"#
            }

            func room(_ index: Int) -> String {
                let room = rooms[index]
                let follows = room.id == "default" ? #"["\#(SpaceNewEntersOwnWorkspaceTests.session)"]"# : "[]"
                return #"{"id":"\#(room.id)","name":"\#(room.name)","index":\#(index),"follows":\#(follows)}"#
            }

            var personal: String {
                let rooms = self.rooms.indices.map(room).joined(separator: ",")
                let pins = pins.map { #"{"session_id":"\#(SpaceNewEntersOwnWorkspaceTests.session)","workspace_key":"\#($0.key)","profile":"\#($0.room)"}"# }
                    .joined(separator: ",")
                return #"{"personal_revision":\#(personalRevision),"sessions":[],"profiles":[\#(rooms)],"pins":[\#(pins)],"groups":[],"workspaces":[],"terminals":[]}"#
            }
        }

        final class Box: Sendable { let value = Mutex(State()) }
        let state = Box()
        let socket: ScriptedDaemonSocket

        init() throws {
            let state = state
            socket = try ScriptedDaemonSocket { request in
                let id = request["id"]?.doubleValue.map { Int($0) } ?? 0
                func ok(_ data: String) -> String { #"{"id":\#(id),"ok":true,"data":\#(data)}"# }
                let personalChanged = #"{"event":"personal-changed"}"#
                let treeChanged = #"{"event":"tree-changed"}"#
                switch request["cmd"]?.stringValue {
                case "identify":
                    let caps = (DaemonCapabilities.shared.required + [DaemonCapabilities.shared.profiles]).map { "\"\($0)\"" }.joined(separator: ",")
                    let revision = state.value.withLock { $0.revision }
                    return [ok(#"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[\#(caps)],"session":"local","pid":7,"registry_id":"\#(SpaceNewEntersOwnWorkspaceTests.session)","generation":"g1","workspace_revision":\#(revision)}"#)]
                case "list-workspaces":
                    return [ok(state.value.withLock { $0.tree })]
                case "list-personal":
                    return [ok(state.value.withLock { $0.personal })]
                case "list-agents":
                    return [ok(#"{"agents":[]}"#)]
                case "create-profile":
                    let room = request["profile"]?.stringValue ?? "prof_new"
                    let name = request["name"]?.stringValue ?? "Space"
                    let snapshot = state.value.withLock { state -> String in
                        state.rooms.append((room, name))
                        state.personalRevision += 1
                        return state.room(state.rooms.count - 1)
                    }
                    return [personalChanged, ok(#"{"profile":\#(snapshot),"changed":true}"#)]
                case "pin-workspace":
                    let key = request["workspace_key"]?.stringValue ?? "", room = request["profile"]?.stringValue ?? ""
                    state.value.withLock { state in
                        state.pins.removeAll { $0.key == key }
                        state.pins.append((key, room))
                        state.personalRevision += 1
                    }
                    return [personalChanged, ok(#"{"changed":true}"#)]
                case "create-workspace":
                    let key = request["key"]?.stringValue ?? UUID().uuidString.lowercased()
                    let (workspace, revision) = state.value.withLock { state -> (Int, Int) in
                        state.nextID += 1
                        state.workspaces.append(Workspace(id: state.nextID, key: key, terminal: false))
                        state.revision += 1
                        return (state.nextID, state.revision)
                    }
                    return [treeChanged, ok(#"{"workspace":\#(workspace),"key":"\#(key)","workspace_revision":\#(revision),"replayed":false}"#)]
                case "create-terminal":
                    let key = request["key"]?.stringValue ?? ""
                    let workspace = state.value.withLock { state -> Int? in
                        guard let index = state.workspaces.firstIndex(where: { $0.key == key }) else { return nil }
                        state.workspaces[index].terminal = true
                        state.revision += 1
                        return state.workspaces[index].id
                    }
                    guard let workspace else { return [#"{"id":\#(id),"ok":false,"error":"no such workspace"}"#] }
                    return [treeChanged, ok(#"{"surface":\#(workspace * 10 + 2),"terminal_id":"\#(UUID().uuidString.lowercased())","pane":\#(workspace * 10 + 1),"screen":\#(workspace * 10),"workspace":\#(workspace),"key":"\#(key)","lifecycle":"running","replayed":false}"#)]
                default:
                    return [ok("{}")]
                }
            }
        }

        func connection() -> DaemonConnection { DaemonConnection(endpoint: DaemonEndpoint(socketPath: socket.path)) }
        func stop() { socket.stop() }
    }

    private static func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(15), sourceLocation: sourceLocation, condition)
    }

    @Test func newSpaceStartsWithItsOwnWorkspaceAndTheWindowShowsIt() async throws {
        let daemon = try RoomsDaemon()
        defer { daemon.stop() }
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.start(makeConnection: { daemon.connection() })
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            services.daemon.shutdownConnection()
        }
        try await Self.waitUntil("home daemon loaded with rooms") {
            services.daemon.store.isLoaded && services.daemon.store.personal.isLoaded && services.daemon.store.workspaces.count == 1
        }
        let window = try #require(services.windows.openWindow(workspaces: [Self.firstKey]))
        services.windows.didActivate(window)
        services.windows.reconcileMembership()
        #expect(window.state.profileID == .defaultProfile)

        let run = RegistryControlBridge(registry: services.registry).performActionTracked(ControlActionRequest(
            actionID: "space.new", origin: "user", focus: true))
        #expect(run.outcome == .ran, "space.new: \(run.outcome)")

        try await Self.waitUntil("the new space's workspace is created and mirrored") {
            services.daemon.store.workspaces.count == 2 && daemon.state.value.withLock { $0.rooms.count == 2 }
        }
        let (room, newKey, pins) = daemon.state.value.withLock { state in
            (state.rooms[1].id, state.workspaces[1].key, state.pins.map { "\($0.key)=\($0.room)" })
        }
        #expect(pins == ["\(newKey)=\(room)"], "the new workspace must be pinned to the new space, pins: \(pins)")
        try await Self.waitUntil("the window shows the new space and its workspace") {
            window.state.profileID.rawValue == room && window.state.workspaceID == newKey
        }
        #expect(WindowProfiles.visible(services.windows.registry.members(of: window.state.id), profile: window.state.profileID,
                                       machines: services.machines) == [newKey],
                "the new space lists only its own workspace")
        #expect(WindowProfiles.visible(services.windows.registry.members(of: window.state.id), profile: .defaultProfile,
                                       machines: services.machines) == [Self.firstKey],
                "the old space keeps only its workspace")
    }
}
