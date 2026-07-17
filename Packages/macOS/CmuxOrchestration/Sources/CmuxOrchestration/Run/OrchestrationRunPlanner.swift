public import Foundation

/// Planning failure with a CLI-ready message.
public struct OrchestrationPlanError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Well-known parameter keys the run path understands. Templates declare
/// these as ordinary parameters; the planner gives them meaning. The raw
/// value is the parameter key as it appears in `orchestration.json`.
public enum OrchestrationWellKnownParameter: String, Sendable, CaseIterable {
    /// Absolute path of the repository tasks operate on. Required by the
    /// worktree and clone-pool substrates.
    case repoRoot = "repo_root"
    /// Directory task workspaces are provisioned under.
    case workspaceRoot = "workspace_root"
    /// Maximum simultaneous task workspaces for one run.
    case concurrency = "concurrency"
    /// Agent id to run tasks with (usually declared as type `agent`).
    case agent = "agent"
}

/// Turns (manifest, resolved parameters, tasks) into a concrete
/// `OrchestrationRunPlan`. Pure planning: reads prompt/layout files through
/// the filesystem seam but performs no side effects — actuation belongs to
/// the app (workspaces) and to substrate execution.
public struct OrchestrationRunPlanner: Sendable {
    public struct Request: Sendable {
        public var installation: InstalledOrchestration
        public var tasks: [OrchestrationTaskInput]
        /// Overrides resolved parameters for this run (`--param k=v`).
        public var parameterOverrides: [String: OrchestrationParameterValue]
        /// Overrides the agent for this run.
        public var agentID: String?
        /// Caller-supplied run identity (planner is pure; no clocks/RNG).
        public var runID: String
        /// The running cmux version, for the `minCmuxVersion` gate. Nil
        /// skips the check (e.g. bare `validate` runs).
        public var cmuxVersion: OrchestrationVersion?
        /// Absolute home directory for `~` expansion.
        public var homeDirectory: String

        public init(
            installation: InstalledOrchestration,
            tasks: [OrchestrationTaskInput],
            parameterOverrides: [String: OrchestrationParameterValue] = [:],
            agentID: String? = nil,
            runID: String,
            cmuxVersion: OrchestrationVersion? = nil,
            homeDirectory: String = NSHomeDirectory()
        ) {
            self.installation = installation
            self.tasks = tasks
            self.parameterOverrides = parameterOverrides
            self.agentID = agentID
            self.runID = runID
            self.cmuxVersion = cmuxVersion
            self.homeDirectory = homeDirectory
        }
    }

    /// Relative path (inside each workspace) of the rendered prompt file.
    public static let promptFileRelativePath = ".cmux/orchestration-prompt.md"

    private let fileSystem: any OrchestrationFileSystem

    public init(fileSystem: any OrchestrationFileSystem = DefaultOrchestrationFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func plan(_ request: Request) throws -> OrchestrationRunPlan {
        let manifest = request.installation.manifest
        var notes: [String] = []

        try checkMinimumVersion(manifest: manifest, cmuxVersion: request.cmuxVersion)
        guard !request.tasks.isEmpty else {
            throw OrchestrationPlanError(message: "No tasks given; pass --task or --tasks-file")
        }

        var parameters = request.installation.record.resolvedParameters
        parameters.merge(request.parameterOverrides) { _, override in override }
        let missing = manifest.parameters.filter { parameters[$0.key] == nil }
        guard missing.isEmpty else {
            let keys = missing.map(\.key).joined(separator: ", ")
            throw OrchestrationPlanError(
                message: "Unanswered parameter(s): \(keys). Re-run the interview or pass --param <key>=<value>"
            )
        }

        let agent = try resolveAgent(manifest: manifest, override: request.agentID)
        let step = manifest.steps?.first
        if let steps = manifest.steps, steps.count > 1 {
            notes.append("Template declares \(steps.count) steps; v1 runs the first step ('\(steps[0].id)') only")
        }
        let promptPath = step?.prompt ?? manifest.prompt
        guard let promptPath else {
            throw OrchestrationPlanError(message: "Template has neither steps nor a top-level prompt")
        }
        let promptTemplate = try readTemplateFile(request.installation, relativePath: promptPath, role: "prompt")
        let layoutJSON = try manifest.layout.map {
            try readTemplateFile(request.installation, relativePath: $0, role: "layout")
        }
        // Digest every template file that shapes provisioning or terminal
        // input, so content-only edits (same paths/commands/version) still
        // invalidate a pending trust confirmation.
        var contentMaterial = "prompt:\(promptPath)\n\(promptTemplate)\u{0}"
        if let layoutJSON {
            contentMaterial += "layout:\(layoutJSON)\u{0}"
        }
        for scriptPath in manifest.substrate.scriptPaths.sorted() {
            let script = try readTemplateFile(request.installation, relativePath: scriptPath, role: "script")
            contentMaterial += "script:\(scriptPath)\n\(script)\u{0}"
        }
        let contentDigest = OrchestrationTrustSummary.sha256Hex(Data(contentMaterial.utf8))

        var tasks = request.tasks
        if case .int(let concurrency)? = parameters[OrchestrationWellKnownParameter.concurrency.rawValue],
           concurrency > 0, tasks.count > concurrency {
            notes.append("\(tasks.count) tasks given; planning the first \(concurrency) (concurrency parameter)")
            tasks = Array(tasks.prefix(concurrency))
        }

        let repoRoot = expandedPath(parameters[OrchestrationWellKnownParameter.repoRoot.rawValue]?.description, home: request.homeDirectory)
        let workspaceRoot = try resolveWorkspaceRoot(
            manifest: manifest,
            parameters: parameters,
            repoRoot: repoRoot,
            homeDirectory: request.homeDirectory
        )

        let runShortID = String(request.runID.prefix(6))
        let groupName = "\(manifest.name) · \(runShortID)"
        var parameterValues: [String: String] = [:]
        for (key, value) in parameters {
            parameterValues[key] = value.description
        }

        var workspaces: [OrchestrationWorkspacePlan] = []
        for (index, task) in tasks.enumerated() {
            workspaces.append(try planWorkspace(
                task: task,
                index: index,
                manifest: manifest,
                installation: request.installation,
                agent: agent,
                promptTemplate: promptTemplate,
                layoutJSON: layoutJSON,
                parameterValues: parameterValues,
                repoRoot: repoRoot,
                workspaceRoot: workspaceRoot,
                runID: request.runID,
                runShortID: runShortID
            ))
        }

        return OrchestrationRunPlan(
            orchestrationName: manifest.name,
            runID: request.runID,
            groupName: groupName,
            agentID: agent.id,
            workspaceRoot: workspaceRoot,
            workspaces: workspaces,
            trust: OrchestrationTrustSummary(
                substrate: manifest.substrate.kind,
                scriptPaths: manifest.substrate.scriptPaths,
                agentCommands: manifest.agents.map { "\($0.id): \($0.command)" },
                workspaceRoot: workspaceRoot,
                templateVersion: manifest.version,
                contentDigest: contentDigest
            ),
            notes: notes
        )
    }

    // MARK: - Pieces

    private func checkMinimumVersion(
        manifest: OrchestrationManifest,
        cmuxVersion: OrchestrationVersion?
    ) throws {
        guard let required = manifest.minCmuxVersion,
              let requiredVersion = OrchestrationVersion(string: required),
              let current = cmuxVersion
        else { return }
        if current < requiredVersion {
            throw OrchestrationPlanError(
                message: "Template requires cmux >= \(requiredVersion), but this is \(current)"
            )
        }
    }

    private func resolveAgent(
        manifest: OrchestrationManifest,
        override: String?
    ) throws -> OrchestrationAgent {
        if let override {
            guard let agent = manifest.agent(withID: override) else {
                let known = manifest.agents.map(\.id).joined(separator: ", ")
                throw OrchestrationPlanError(
                    message: "Unknown agent '\(override)'; template declares: \(known)"
                )
            }
            return agent
        }
        guard let agent = manifest.effectiveDefaultAgent else {
            throw OrchestrationPlanError(message: "Template declares no agents")
        }
        return agent
    }

    private func resolveWorkspaceRoot(
        manifest: OrchestrationManifest,
        parameters: [String: OrchestrationParameterValue],
        repoRoot: String?,
        homeDirectory: String
    ) throws -> String {
        if let explicit = parameters[OrchestrationWellKnownParameter.workspaceRoot.rawValue]?.description,
           !explicit.isEmpty {
            return expandedPath(explicit, home: homeDirectory) ?? explicit
        }
        switch manifest.substrate {
        case .worktree, .clonePool:
            guard let repoRoot else {
                throw OrchestrationPlanError(
                    message: "The \(manifest.substrate.kind.rawValue) substrate needs a '\(OrchestrationWellKnownParameter.repoRoot.rawValue)' parameter"
                )
            }
            return repoRoot + "/.cmux/orchestrations/" + manifest.name
        case .script:
            return homeDirectory + "/.cmuxterm/orchestrations/" + manifest.name + "/workspaces"
        }
    }

    private func planWorkspace(
        task: OrchestrationTaskInput,
        index: Int,
        manifest: OrchestrationManifest,
        installation: InstalledOrchestration,
        agent: OrchestrationAgent,
        promptTemplate: String,
        layoutJSON: String?,
        parameterValues: [String: String],
        repoRoot: String?,
        workspaceRoot: String,
        runID: String,
        runShortID: String
    ) throws -> OrchestrationWorkspacePlan {
        let taskNumber = index + 1
        let taskSlug = OrchestrationPlaceholders().slug(task.title)
        let directoryName = "\(runShortID)-t\(taskNumber)" + (taskSlug.isEmpty ? "" : "-\(taskSlug)")
        let directory = workspaceRoot + "/" + directoryName

        let branchPrefix: String
        if case .worktree(let prefix) = manifest.substrate, let prefix, !prefix.isEmpty {
            branchPrefix = prefix
        } else {
            branchPrefix = manifest.name
        }
        let branch = "\(branchPrefix)/\(runShortID)-t\(taskNumber)" + (taskSlug.isEmpty ? "" : "-\(taskSlug)")

        let provision: OrchestrationProvisionSpec
        switch manifest.substrate {
        case .worktree:
            guard let repoRoot else {
                throw OrchestrationPlanError(
                    message: "The worktree substrate needs a '\(OrchestrationWellKnownParameter.repoRoot.rawValue)' parameter"
                )
            }
            provision = .gitWorktree(repoRoot: repoRoot, branch: branch)
        case .clonePool:
            guard let repoRoot else {
                throw OrchestrationPlanError(
                    message: "The clone-pool substrate needs a '\(OrchestrationWellKnownParameter.repoRoot.rawValue)' parameter"
                )
            }
            provision = .gitClone(repoRoot: repoRoot, branch: branch)
        case .script(let provisionScript, _):
            provision = .script(scriptPath: installation.templateDirectory + "/" + provisionScript)
        }

        var taskText = task.title
        if let body = task.body, !body.isEmpty {
            taskText += "\n\n" + body
        }
        var values = parameterValues
        values["task"] = taskText
        values["task_index"] = String(taskNumber)
        values["task_slug"] = taskSlug
        values["branch"] = branch
        values["workspace_dir"] = directory
        values["issue_number"] = task.issueNumber.map(String.init) ?? ""
        values["orchestration_name"] = manifest.name
        values["run_id"] = runID

        let renderedPrompt: String
        do {
            renderedPrompt = try OrchestrationPlaceholders().render(promptTemplate, values: values)
        } catch {
            throw OrchestrationPlanError(message: "Prompt template: \(String(describing: error))")
        }

        let promptFile = Self.promptFileRelativePath
        values["prompt"] = OrchestrationPlaceholders().shellQuoted(renderedPrompt)
        // Quoted like {{prompt}}: constant relative path today, but quoting keeps
        // agent commands safe if the location ever gains spaces.
        values["prompt_file"] = OrchestrationPlaceholders().shellQuoted(promptFile)

        let commandText: String
        do {
            commandText = try OrchestrationPlaceholders().render(agent.command, values: values)
        } catch {
            throw OrchestrationPlanError(message: "Agent '\(agent.id)' command: \(String(describing: error))")
        }

        return OrchestrationWorkspacePlan(
            title: "\(manifest.name) \(taskNumber): \(task.title)",
            directory: directory,
            branch: branch,
            provision: provision,
            filesToWrite: [OrchestrationPlannedFile(relativePath: promptFile, contents: renderedPrompt)],
            commandText: commandText,
            env: [
                "CMUX_ORCHESTRATION": manifest.name,
                "CMUX_ORCHESTRATION_RUN": runID,
                "CMUX_ORCHESTRATION_TASK": String(taskNumber),
                "CMUX_ORCHESTRATION_BRANCH": branch,
            ],
            layoutJSON: layoutJSON
        )
    }

    private func readTemplateFile(
        _ installation: InstalledOrchestration,
        relativePath: String,
        role: String
    ) throws -> String {
        let absolute = installation.templateDirectory + "/" + relativePath
        guard fileSystem.fileExists(atPath: absolute),
              let data = try? fileSystem.readData(atPath: absolute),
              let text = String(data: data, encoding: .utf8)
        else {
            throw OrchestrationPlanError(
                message: "Template \(role) file '\(relativePath)' is missing or unreadable"
            )
        }
        return text
    }

    private func expandedPath(_ path: String?, home: String) -> String? {
        guard var path, !path.isEmpty else { return nil }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        }
        return path
    }
}
