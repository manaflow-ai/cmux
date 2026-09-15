public import Foundation

/// One row of the daemon's `terminal.list` result. Only the fields the phone
/// needs are decoded; unknown keys are kept out of the way by `JSONDecoder`.
public struct TerminalSummary: Sendable, Equatable, Codable {
    public var id: String
    public var name: String?
    public var workspaceID: String?

    public init(id: String, name: String? = nil, workspaceID: String? = nil) {
        self.id = id
        self.name = name
        self.workspaceID = workspaceID
    }
}

/// A workspace owned by the remote cmux daemon. This is the stable identity
/// used by Cloud clients when they project a workspace locally.
public struct RemoteWorkspaceSummary: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String?
    public var root: String?

    public init(id: String, name: String? = nil, root: String? = nil) {
        self.id = id
        self.name = name
        self.root = root
    }

    public var preferredName: String {
        if let name, !name.isEmpty { return name }
        return root?.split(separator: "/").last.map(String.init) ?? id
    }
}

/// Decoding of the JSON the C ABI hands back.
public struct TerminalCatalogDecoding {
    public init() {}

    /// `terminal.list` returns an array of terminal snapshots.
    public static func terminals(fromListResult data: Data) throws -> [TerminalSummary] {
        try JSONDecoder().decode([TerminalSummary].self, from: data)
    }

    /// `workspace.list` is returned as `{ "workspaces": [...] }` by the
    /// cmux protocol. A bare array is accepted for older daemons.
    public static func workspaces(fromListResult data: Data) throws -> [RemoteWorkspaceSummary] {
        if let wrapped = try? JSONDecoder().decode(WorkspaceListResponse.self, from: data) {
            return wrapped.workspaces
        }
        return try JSONDecoder().decode([RemoteWorkspaceSummary].self, from: data)
    }

    /// Extracts the workspace id from `workspace.create`'s mutation result.
    public static func createdWorkspaceID(fromCreateResult data: Data) throws -> String {
        struct MutationResult: Decodable {
            struct CreatedPath: Decodable {
                var kind: String?
                var workspace_id: String?
            }
            var value: CreatedPath?
        }
        let result = try JSONDecoder().decode(MutationResult.self, from: data)
        guard let id = result.value?.workspace_id, !id.isEmpty else {
            throw TerminalCatalogError.missingCreatedWorkspace
        }
        return id
    }

    private struct WorkspaceListResponse: Decodable {
        var workspaces: [RemoteWorkspaceSummary]
    }

    /// `workspace.create` with `initial_content: terminal` returns
    /// `MutationResult<CreatedPath>`: the created path sits under `value`,
    /// discriminated by `kind`, and a terminal path carries `terminal_id`.
    public static func createdTerminalID(fromCreateResult data: Data) throws -> String {
        struct MutationResult: Decodable {
            struct CreatedPath: Decodable {
                var kind: String?
                var terminal_id: String?
            }
            var value: CreatedPath?
        }
        let result = try JSONDecoder().decode(MutationResult.self, from: data)
        guard let id = result.value?.terminal_id, !id.isEmpty else {
            throw TerminalCatalogError.missingCreatedTerminal
        }
        return id
    }
}

public enum TerminalCatalogError: Error, Equatable, Sendable {
    case missingCreatedTerminal
    case missingCreatedWorkspace
}

/// Raw output kinds, mirroring `CMUX_TERMINAL_OUTPUT_*` in the C header.
public enum TerminalOutputEvent: Sendable, Equatable {
    /// Replay bytes for a fresh emulator sized `cols` x `rows`.
    case snapshot(replay: Data, cols: UInt16, rows: UInt16)
    case output(Data)
    case resized(cols: UInt16, rows: UInt16)
    case exited

    /// Build an event from the C callback arguments. Returns nil for a kind
    /// this build does not know, so a newer library never crashes an old app.
    public init?(kind: UInt32, bytes: Data, cols: UInt16, rows: UInt16) {
        switch kind {
        case 1: self = .snapshot(replay: bytes, cols: cols, rows: rows)
        case 2: self = .output(bytes)
        case 3: self = .resized(cols: cols, rows: rows)
        case 4: self = .exited
        default: return nil
        }
    }
}
