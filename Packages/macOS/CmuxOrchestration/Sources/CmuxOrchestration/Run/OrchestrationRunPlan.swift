import CryptoKit
public import Foundation

/// One unit of work fed into a run. v1 tasks come from `--task` /
/// `--tasks-file`; the fleet engine will later feed these from issue
/// queues and other work sources.
public struct OrchestrationTaskInput: Sendable, Hashable, Codable {
    public var title: String
    public var body: String?
    public var issueNumber: Int?

    public init(title: String, body: String? = nil, issueNumber: Int? = nil) {
        self.title = title
        self.body = body
        self.issueNumber = issueNumber
    }
}

/// How one task workspace's directory comes into existence.
public enum OrchestrationProvisionSpec: Sendable, Hashable, Codable {
    /// `git worktree add -b <branch> <directory>` from `repoRoot`.
    case gitWorktree(repoRoot: String, branch: String)
    /// A fresh full clone of `repoRoot` checked out on `branch`.
    /// (v1 interpretation of clone-pool: clone per task; pool reuse/reset
    /// belongs to the fleet engine.)
    case gitClone(repoRoot: String, branch: String)
    /// Run the template's provision script with the workspace directory as
    /// its argument. Script substrates execute template-authored code and
    /// are called out in the trust summary.
    case script(scriptPath: String)

    enum CodingKeys: String, CodingKey {
        case kind
        case repoRoot
        case branch
        case scriptPath
    }

    enum Kind: String, Codable {
        case gitWorktree = "git-worktree"
        case gitClone = "git-clone"
        case script
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        switch Kind(rawValue: kindString) {
        case .gitWorktree:
            self = .gitWorktree(
                repoRoot: try container.decode(String.self, forKey: .repoRoot),
                branch: try container.decode(String.self, forKey: .branch)
            )
        case .gitClone:
            self = .gitClone(
                repoRoot: try container.decode(String.self, forKey: .repoRoot),
                branch: try container.decode(String.self, forKey: .branch)
            )
        case .script:
            self = .script(scriptPath: try container.decode(String.self, forKey: .scriptPath))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown provision kind '\(kindString)'"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gitWorktree(let repoRoot, let branch):
            try container.encode(Kind.gitWorktree.rawValue, forKey: .kind)
            try container.encode(repoRoot, forKey: .repoRoot)
            try container.encode(branch, forKey: .branch)
        case .gitClone(let repoRoot, let branch):
            try container.encode(Kind.gitClone.rawValue, forKey: .kind)
            try container.encode(repoRoot, forKey: .repoRoot)
            try container.encode(branch, forKey: .branch)
        case .script(let scriptPath):
            try container.encode(Kind.script.rawValue, forKey: .kind)
            try container.encode(scriptPath, forKey: .scriptPath)
        }
    }
}

/// A file the actuator writes into the provisioned workspace before the
/// agent command is sent (rendered prompt, run metadata).
public struct OrchestrationPlannedFile: Sendable, Hashable, Codable {
    /// Path relative to the workspace directory.
    public var relativePath: String
    public var contents: String

    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

/// Everything needed to actuate one task workspace.
public struct OrchestrationWorkspacePlan: Sendable, Hashable, Codable {
    /// Sidebar title, e.g. `issue-fleet 1: fix flaky test`.
    public var title: String
    /// Absolute workspace directory (cwd of the created cmux workspace).
    public var directory: String
    public var branch: String?
    public var provision: OrchestrationProvisionSpec
    public var filesToWrite: [OrchestrationPlannedFile]
    /// Text typed into the workspace's terminal (the actuator appends the
    /// newline). Runs in the user's login shell with the user's own auth.
    public var commandText: String
    /// Workspace environment variables (`CMUX_ORCHESTRATION*`).
    public var env: [String: String]
    /// Raw JSON of the template's saved-layout file, passed through to
    /// workspace creation untouched.
    public var layoutJSON: String?

    public init(
        title: String,
        directory: String,
        branch: String? = nil,
        provision: OrchestrationProvisionSpec,
        filesToWrite: [OrchestrationPlannedFile] = [],
        commandText: String,
        env: [String: String] = [:],
        layoutJSON: String? = nil
    ) {
        self.title = title
        self.directory = directory
        self.branch = branch
        self.provision = provision
        self.filesToWrite = filesToWrite
        self.commandText = commandText
        self.env = env
        self.layoutJSON = layoutJSON
    }
}

/// What the user must see and confirm before a template's first run:
/// exactly which template-authored things will execute on their machine.
public struct OrchestrationTrustSummary: Sendable, Hashable, Codable {
    public var substrate: OrchestrationSubstrate.Kind
    /// Template-relative script paths the run would execute (script
    /// substrate only — empty for cmux-native substrates).
    public var scriptPaths: [String]
    /// Raw (unrendered) agent command templates.
    public var agentCommands: [String]
    public var workspaceRoot: String
    /// Template version the summary was built from.
    public var templateVersion: String
    /// Digest of the executable template contents (prompt, layout, and
    /// substrate script bytes), so content edits invalidate a pending
    /// confirmation even when paths, commands, and version are unchanged.
    public var contentDigest: String

    public init(
        substrate: OrchestrationSubstrate.Kind,
        scriptPaths: [String],
        agentCommands: [String],
        workspaceRoot: String,
        templateVersion: String,
        contentDigest: String
    ) {
        self.substrate = substrate
        self.scriptPaths = scriptPaths
        self.agentCommands = agentCommands
        self.workspaceRoot = workspaceRoot
        self.templateVersion = templateVersion
        self.contentDigest = contentDigest
    }

    /// Hex SHA-256 of arbitrary material, used for `contentDigest` and
    /// `fingerprint`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable digest of the trust-relevant material (substrate, scripts,
    /// agent commands, template version, and the content digest). A client
    /// that showed the user a plan echoes this back with its confirmation,
    /// so a template that changed between review and run is rejected
    /// instead of silently confirmed (time-of-check/time-of-use).
    public var fingerprint: String {
        var material = "v2\n"
        material += substrate.rawValue + "\n"
        material += templateVersion + "\n"
        material += "content:" + contentDigest + "\n"
        for script in scriptPaths {
            material += "script:" + script + "\n"
        }
        for command in agentCommands {
            material += "agent:" + command + "\n"
        }
        return Self.sha256Hex(Data(material.utf8))
    }
}

/// A fully-resolved run: N workspaces, grouped in the sidebar, plus the
/// trust summary to show before execution.
public struct OrchestrationRunPlan: Sendable, Hashable, Codable {
    public var orchestrationName: String
    public var runID: String
    /// Sidebar workspace-group name, e.g. `issue-fleet · a1b2c3`.
    public var groupName: String
    public var agentID: String
    public var workspaceRoot: String
    public var workspaces: [OrchestrationWorkspacePlan]
    public var trust: OrchestrationTrustSummary
    /// Human-readable caveats (e.g. task count capped by concurrency).
    public var notes: [String]

    public init(
        orchestrationName: String,
        runID: String,
        groupName: String,
        agentID: String,
        workspaceRoot: String,
        workspaces: [OrchestrationWorkspacePlan],
        trust: OrchestrationTrustSummary,
        notes: [String] = []
    ) {
        self.orchestrationName = orchestrationName
        self.runID = runID
        self.groupName = groupName
        self.agentID = agentID
        self.workspaceRoot = workspaceRoot
        self.workspaces = workspaces
        self.trust = trust
        self.notes = notes
    }
}
