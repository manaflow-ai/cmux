public import CmuxNextDaemon
public import Foundation
import os

/// Serves one admitted phone connection's shipped-iOS mobile RPC dialect
/// from the daemon. Events (`workspace.updated`, `terminal.bytes`) go out
/// through `emit`, which the host writes as frames on the control stream.
///
/// State is per connection: terminal streams, the event subscription, and
/// the phone's selected workspace. Phone focus never moves the Mac's view.
public actor MobileCompatSession {
    public typealias Emit = @Sendable (_ eventJSON: Data) async -> Void

    let backend: any MobileCompatBackend
    let host: MobileCompatHostInfo
    let emit: Emit
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.compat")
    var subscribed = false
    var workspaceUpdatePending = false
    var treeWatch: Task<Void, Never>?
    var selectedWorkspace: WorkspaceKey?
    var streams: [String: MobileCompatTerminalStream] = [:]
    /// Next byte offset per surface, carried across stream replacements.
    var surfaceSeq: [String: UInt64] = [:]
    /// Last located tab per uppercased surface id (input fast path).
    var locations: [String: MobileWorkspaceRows.TerminalLocation] = [:]

    public init(backend: any MobileCompatBackend, host: MobileCompatHostInfo, emit: @escaping Emit) {
        self.backend = backend
        self.host = host
        self.emit = emit
    }

    /// Answers one request frame with one response frame payload.
    public func handle(frame: Data) async -> Data {
        guard let request = MobileRPCRequest(frame: frame) else {
            return MobileRPCWire.failure(id: .null, error: .invalidParams("request is not a JSON object"))
        }
        do {
            let result = try await dispatch(request)
            return MobileRPCWire.success(id: request.id, result: result)
        } catch let error as MobileRPCError {
            return MobileRPCWire.failure(id: request.id, error: error)
        } catch {
            logger.error("\(request.method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return MobileRPCWire.failure(id: request.id, error: MobileRPCError("internal_error", "\(error)"))
        }
    }

    /// Ends every stream (the connection closed).
    public func close() async {
        treeWatch?.cancel()
        treeWatch = nil
        for stream in streams.values { await stream.stop() }
        streams.removeAll()
    }

    func dispatch(_ request: MobileRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "mobile.host.status":
            return host.statusPayload
        case "mobile.rpc.methods":
            return .object(["schema_version": .int(1), "methods": .strings(MobileCompatMethods.served)])
        case "mobile.events.subscribe":
            return subscribe(request)
        case "mobile.events.unsubscribe":
            unsubscribe()
            return .object(["unsubscribed": .bool(true)])
        case "mobile.events.probe":
            return .object(["stream_id": .string(request.string("stream_id") ?? "events"),
                            "subscribed": .bool(subscribed), "event_transport": .string("control")])
        case "mobile.workspace.list", "workspace.list":
            return try await workspaceList()
        case "workspace.create":
            return try await createWorkspace(request)
        case "workspace.close":
            return try await closeWorkspace(request)
        case "workspace.action":
            return try await workspaceAction(request)
        case "mobile.surface.focus":
            return .object(["focused": .bool(true)])
        default:
            if let result = try await dispatchTerminal(request) { return result }
            throw MobileRPCError.methodNotFound(request.method)
        }
    }

    // MARK: Events

    private func subscribe(_ request: MobileRPCRequest) -> JSONValue {
        let already = subscribed
        subscribed = true
        if treeWatch == nil {
            let changes = backend.treeChanges()
            treeWatch = Task { [weak self] in
                for await _ in changes { await self?.treeChanged() }
            }
        }
        // All events ride the control stream: no server event lanes.
        return .object([
            "stream_id": .string(request.string("stream_id") ?? "events"),
            "already_subscribed": .bool(already),
            "event_transport": .string("control"),
        ])
    }

    private func unsubscribe() {
        subscribed = false
        treeWatch?.cancel()
        treeWatch = nil
    }

    /// One `workspace.updated` per refetch: further changes before the phone
    /// lists again are covered by that list.
    private func treeChanged() async {
        guard subscribed, !workspaceUpdatePending else { return }
        workspaceUpdatePending = true
        await emit(MobileRPCWire.event(topic: "workspace.updated", payload: .object([:])))
    }

    // MARK: Workspaces

    func workspaceList(createdWorkspace: WorkspaceKey? = nil, createdTerminal: TerminalID? = nil) async throws
        -> JSONValue {
        workspaceUpdatePending = false
        let tree = try await backend.tree()
        return MobileWorkspaceRows.result(for: tree, selected: selectedWorkspace,
                                          createdWorkspace: createdWorkspace, createdTerminal: createdTerminal)
    }

    private func createWorkspace(_ request: MobileRPCRequest) async throws -> JSONValue {
        let key = try await backend.createWorkspace(name: request.string("title") ?? request.string("name"))
        let terminal = try await backend.createTerminal(in: key, cwd: request.string("cwd"))
        selectedWorkspace = key
        return try await workspaceList(createdWorkspace: key, createdTerminal: terminal)
    }

    private func closeWorkspace(_ request: MobileRPCRequest) async throws -> JSONValue {
        let key = try workspaceKey(request)
        try await backend.closeWorkspace(key)
        if selectedWorkspace == key { selectedWorkspace = nil }
        return .object(["workspace_id": .string(MobileCompatIDs.workspaceID(key)), "closed": .bool(true)])
    }

    private func workspaceAction(_ request: MobileRPCRequest) async throws -> JSONValue {
        let key = try workspaceKey(request)
        let action = request.string("action") ?? ""
        switch action {
        case "rename":
            guard let title = request.string("title")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { throw MobileRPCError.invalidParams("Missing or invalid title") }
            try await backend.renameWorkspace(key, to: title)
            return .object(["action": .string(action), "workspace_id": .string(MobileCompatIDs.workspaceID(key)),
                            "title": .string(title)])
        case "mark_read", "mark_unread":
            // Read state is per client in the daemon; nothing shared changes.
            return .object(["action": .string(action), "workspace_id": .string(MobileCompatIDs.workspaceID(key))])
        default:
            throw MobileRPCError("unsupported_action", "\(action) is not supported by this Mac")
        }
    }

    func workspaceKey(_ request: MobileRPCRequest) throws -> WorkspaceKey {
        guard let id = request.string("workspace_id"), let key = MobileCompatIDs.workspaceKey(id) else {
            throw MobileRPCError.invalidParams("workspace_id must be a UUID")
        }
        return key
    }
}
