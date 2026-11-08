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

    /// The cheap, read-only source probe used by the Import Suggestions scan. The daemon
    /// returns candidate folders from its project index without building the full adoption plan.
    public func detect() async throws -> ConductorImportDetection {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "conductor_import.plan",
                                    params: ["detect_only": .bool(true)], idempotencyKey: nil)
        }, as: ConductorImportDetection.self)
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

/// Metadata returned by `conductor_import.plan { detect_only: true }`. The card is deliberately
/// optional: a source scan may find no candidate folders, while `hasConductor` still tells the
/// executor whether Conductor-specific copy and deadline language is valid.
public struct ConductorImportDetection: Decodable, Sendable, Equatable {
    public struct Card: Decodable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var name: String
        public var count: Int?
    }

    public var found: JSONValue
    public var candidateFolders: [String: Int]
    public var hasConductor: Bool
    public var card: Card?

    enum CodingKeys: String, CodingKey {
        case found
        case candidateFolders = "candidate_folders"
        case hasConductor = "has_conductor"
        case card
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        found = try container.decodeIfPresent(JSONValue.self, forKey: .found) ?? .null
        candidateFolders = try container.decodeIfPresent([String: Int].self, forKey: .candidateFolders) ?? [:]
        // Older daemons had no generic source bit; preserving true keeps their Conductor cards
        // and executor previews unchanged while this app remains wire-compatible.
        hasConductor = try container.decodeIfPresent(Bool.self, forKey: .hasConductor) ?? true
        card = try container.decodeIfPresent(Card.self, forKey: .card)
    }
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
        /// The worktree recipe the import saves on the project; nil when there is none, or the
        /// project already has one of its own.
        public var recipe: Recipe?

        enum CodingKeys: String, CodingKey {
            case repoID = "repo_id", name, path, skipped, setup, teardown, worktreeinclude, envNames = "env_names", workspaces, recipe
        }
    }

    /// A project's worktree recipe in cmux's shape (`project.update` `worktree`), and the
    /// project it is saved on.
    public struct Recipe: Decodable, Sendable, Equatable {
        public var projectPath: String
        public var setup: String?
        public var teardown: String?
        public var run: String?
        public var include: [String]?

        enum CodingKeys: String, CodingKey {
            case projectPath = "project_path", setup, teardown, run, include
        }

        /// The `worktree` value `project.update` saves.
        public var worktree: JSONValue {
            var fields: [String: JSONValue] = [:]
            if let setup { fields["setup"] = .string(setup) }
            if let teardown { fields["teardown"] = .string(teardown) }
            if let run { fields["run"] = .string(run) }
            if let include, !include.isEmpty { fields["include"] = .array(include.map { .string($0) }) }
            return .object(fields)
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
    /// False when the plan came from generic agent worktree sources rather than Conductor.
    /// Missing on older daemons, where the only source was Conductor.
    public var hasConductor: Bool
    public var projects: [Project]
    /// cmux workspaces a cut-off run half made: closed before they are made again.
    public var cleanup: [String]
    public var warnings: [Warning]

    enum CodingKeys: String, CodingKey {
        case cloudShutdown = "cloud_shutdown", hasConductor = "has_conductor", projects, cleanup, warnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cloudShutdown = try container.decode(String.self, forKey: .cloudShutdown)
        hasConductor = try container.decodeIfPresent(Bool.self, forKey: .hasConductor) ?? true
        projects = try container.decode([Project].self, forKey: .projects)
        cleanup = try container.decode([String].self, forKey: .cleanup)
        warnings = try container.decode([Warning].self, forKey: .warnings)
    }

    /// The workspaces this run adopts, with their project.
    /// Each imported project's worktree recipe to save, in plan order.
    public var recipes: [(project: Project, recipe: Recipe)] {
        projects.compactMap { project in
            guard project.skipped == nil, let recipe = project.recipe else { return nil }
            return (project, recipe)
        }
    }

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
