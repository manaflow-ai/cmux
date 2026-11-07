import Foundation

/// Import from Conductor on the daemon (`conductor_import.*`, the
/// `cmux-conductor-import` crate): the dry run of what Conductor's repositories
/// and workspaces become here, and the ledger that keeps a rerun from making
/// anything twice. The daemon reads Conductor's files read-only; the app makes
/// the projects and workspaces the person confirms.
public struct ConductorImportClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// `conductor_import.plan`: what an import would make now. Nil plan when
    /// nothing of Conductor's is on this machine.
    public func plan() async throws -> ConductorImportReply {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "conductor_import.plan", params: [:], idempotencyKey: nil)
        }, as: ConductorImportReply.self)
    }

    /// `conductor_import.record`: Conductor workspace `workspace` is being made
    /// (`pending`, with the cmux workspace once there is one) or made (`done`).
    public func record(workspace: String, stage: ConductorImportStage, cmuxWorkspace: String?,
                       runCompleted: Bool = false, idempotencyKey: String) async throws {
        var params: [String: JSONValue] = ["workspace": .string(workspace), "stage": .string(stage.rawValue)]
        if let cmuxWorkspace { params["cmux_workspace"] = .string(cmuxWorkspace) }
        if runCompleted { params["run_completed"] = .bool(true) }
        let fields = params
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "conductor_import.record", params: fields, idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}

public enum ConductorImportStage: String, Sendable {
    case pending, done
}

public struct ConductorImportReply: Decodable, Sendable {
    public var plan: ConductorImportPlan?
    public var error: String?
}

/// The dry run, as `cmux_conductor_import::plan::Plan` serializes it.
public struct ConductorImportPlan: Decodable, Sendable, Equatable {
    public struct Project: Decodable, Sendable, Equatable {
        public var repoID: String
        public var name: String
        public var path: String?
        /// Why it is not imported (hidden in Conductor, folder gone).
        public var skipped: String?
        public var setup: String?
        public var teardown: String?
        public var worktreeinclude: [String]
        public var envNames: [String]
        public var workspaces: [Workspace]

        enum CodingKeys: String, CodingKey {
            case repoID = "repo_id", name, path, skipped, setup, teardown, worktreeinclude, envNames = "env_names", workspaces
        }
    }

    public struct Workspace: Decodable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var branch: String?
        public var path: String?
        public var disposition: Disposition
        /// What the import makes without being asked: live workspaces not imported before.
        public var checked: Bool
        public var chats: Chats?
    }

    public struct Disposition: Decodable, Sendable, Equatable {
        /// `adopt`, `recoverable`, `already-imported` or `skip`.
        public var kind: String
        /// The commit or branch a recoverable workspace comes back from.
        public var from: String?
        public var reason: String?
    }

    public struct Chats: Decodable, Sendable, Equatable {
        public var transcripts: Int
    }

    public struct Warning: Decodable, Sendable, Equatable {
        public var code: String
        public var detail: String
    }

    public var cloudShutdown: String
    public var projects: [Project]
    /// cmux workspaces a cut-off run half made: closed before they are made again.
    public var cleanup: [String]
    public var warnings: [Warning]

    enum CodingKeys: String, CodingKey {
        case cloudShutdown = "cloud_shutdown", projects, cleanup, warnings
    }

    /// The workspaces this run adopts, with their project.
    public var adopting: [(project: Project, workspace: Workspace)] {
        projects.filter { $0.skipped == nil }.flatMap { project in
            project.workspaces.filter { $0.checked && $0.disposition.kind == "adopt" }.map { (project, $0) }
        }
    }

    /// Archived workspaces whose commit or branch still exists: listed, not made.
    public var recoverable: [Workspace] {
        projects.flatMap(\.workspaces).filter { $0.disposition.kind == "recoverable" }
    }
}
