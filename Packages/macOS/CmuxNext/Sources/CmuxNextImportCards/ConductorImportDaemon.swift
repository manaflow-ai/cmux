import CmuxNextDaemon

/// The daemon calls Import from Conductor makes (``ConductorImport``): the dry run, the project
/// list, closing a cut-off run's workspaces, adding projects, saving their worktree recipes and
/// the ledger's records. The App's
/// is ``LiveConductorImportDaemon``; a test drives the run with its own.
@MainActor
protocol ConductorImportDaemon {
    /// `conductor_import.plan`.
    func plan() async throws -> ConductorImportReply
    /// The listed projects' paths (`project.list`).
    func projectPaths(limit: Int) async throws -> [String]
    /// Closes workspace `key`, ending its terminals.
    func closeWorkspace(_ key: WorkspaceKey) async throws
    /// `project.add`.
    func addProject(path: String, idempotencyKey: String) async throws
    /// `project.update` `worktree`: the project's worktree recipe, unless one is already saved.
    func saveRecipe(_ recipe: ConductorImportPlan.Recipe, idempotencyKey: String) async throws
    /// `conductor_import.record`.
    func record(workspace: String, stage: ConductorImportStage, cmuxWorkspace: String?, runCompleted: Bool,
                idempotencyKey: String) async throws
}

/// ``ConductorImportDaemon`` on this Mac's daemon connection.
struct LiveConductorImportDaemon: ConductorImportDaemon {
    let connection: DaemonConnection

    init(connection: DaemonConnection) {
        self.connection = connection
    }

    func plan() async throws -> ConductorImportReply {
        try await ConductorImportClient(connection: connection).plan()
    }

    func projectPaths(limit: Int) async throws -> [String] {
        try await ProjectStateClient(connection: connection).listPaths(query: nil, limit: limit)
    }

    func closeWorkspace(_ key: WorkspaceKey) async throws {
        try await connection.closeWorkspace(key, endTerminals: true)
    }

    func addProject(path: String, idempotencyKey: String) async throws {
        try await ProjectStateClient(connection: connection).add(path: path, idempotencyKey: idempotencyKey)
    }

    func saveRecipe(_ recipe: ConductorImportPlan.Recipe, idempotencyKey: String) async throws {
        try await ProjectStateClient(connection: connection)
            .saveWorktreeRecipe(path: recipe.projectPath, worktree: recipe.worktree, keepSaved: true,
                                idempotencyKey: idempotencyKey)
    }

    func record(workspace: String, stage: ConductorImportStage, cmuxWorkspace: String?, runCompleted: Bool,
                idempotencyKey: String) async throws {
        try await ConductorImportClient(connection: connection)
            .record(workspace: workspace, stage: stage, cmuxWorkspace: cmuxWorkspace, runCompleted: runCompleted,
                    idempotencyKey: idempotencyKey)
    }
}
