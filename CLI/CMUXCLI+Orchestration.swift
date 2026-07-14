import CmuxOrchestration
import Foundation

/// `cmux orchestration` — shareable fleet templates.
///
/// Store verbs (init/validate/install/list/info/remove/update/configure)
/// run entirely in the CLI process against `~/.cmuxterm/orchestrations`, so
/// they work without a running app. `run`/`plan` go through the v2 socket
/// (`orchestration.*`) so the app owns workspace actuation.
extension CMUXCLI {
    static func orchestrationHelpText() -> String {
        """
        Usage: cmux orchestration <subcommand> [flags]

        Install and run shareable orchestration templates (fleets of coding
        agents: prompts, workspace shapes, agent commands, provisioning).

        Subcommands:
          init <name> [--dir <path>]        Scaffold a new template
          validate [path]                   Lint a template directory
          install <git-url-or-path> [--ref <branch>] [--force] [--param k=v ...]
          list [--json]                     List installed templates
          info <name> [--json]              Show one installed template
          remove <name>                     Uninstall a template
          update <name>                     Re-fetch a template from its source
          configure <name> [--param k=v ...]  Answer or change parameters
          plan <name> --task <t> [...]      Show what a run would do (no socket writes)
          run <name> --task <t> [...]       Provision workspaces and start agents

        Run flags:
          --task <text>       Task to dispatch (repeatable)
          --tasks-file <path> One task per line ('#' comments ignored)
          --param k=v         Per-run parameter override (repeatable)
          --agent <id>        Agent declared in the template
          --dry-run           Alias for plan
          --yes               Skip the first-run trust confirmation

        Install never executes template code. Before the first run, cmux
        shows the template's scripts, agent commands, and substrate and asks
        for confirmation.
        """
    }

    /// Subcommands that need the app socket (everything else is CLI-local).
    static func orchestrationCommandNeedsSocket(_ commandArgs: [String]) -> Bool {
        switch commandArgs.first?.lowercased() {
        case "run", "plan":
            return true
        default:
            return false
        }
    }

    func runOrchestrationLocalNamespace(commandArgs: [String], jsonOutput: Bool) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "orchestration requires a subcommand. Try: cmux orchestration --help")
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "init":
            try runOrchestrationInit(commandArgs: rest)
        case "validate":
            try runOrchestrationValidate(commandArgs: rest, jsonOutput: jsonOutput)
        case "install":
            try runOrchestrationInstall(commandArgs: rest)
        case "list", "ls":
            try runOrchestrationList(commandArgs: rest, jsonOutput: jsonOutput)
        case "info":
            try runOrchestrationInfo(commandArgs: rest, jsonOutput: jsonOutput)
        case "remove", "rm", "delete", "uninstall":
            try runOrchestrationRemove(commandArgs: rest)
        case "update":
            try runOrchestrationUpdate(commandArgs: rest)
        case "configure":
            try runOrchestrationConfigure(commandArgs: rest)
        default:
            throw CLIError(message: "Unknown orchestration subcommand: \(subcommand). Try: cmux orchestration --help")
        }
    }

    // MARK: - init / validate

    private func runOrchestrationInit(commandArgs: [String]) throws {
        let (dirOpt, remaining) = parseOption(commandArgs, name: "--dir")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration init: unknown flag '\(unknown)'")
        }
        guard let name = remaining.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "orchestration init requires <name>")
        }
        let directory = resolvePath(dirOpt ?? FileManager.default.currentDirectoryPath)
        do {
            try OrchestrationScaffold().scaffold(name: name, directory: directory)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        print("Scaffolded orchestration '\(name)' in \(directory)")
        print("Edit orchestration.json and prompts/task.md, then: cmux orchestration install \(directory)")
    }

    private func runOrchestrationValidate(commandArgs: [String], jsonOutput: Bool) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "orchestration validate: unknown flag '\(unknown)'")
        }
        let path = resolvePath(commandArgs.first(where: { !$0.hasPrefix("--") }) ?? FileManager.default.currentDirectoryPath)
        let report = OrchestrationValidator().validate(templateDirectory: path)
        if jsonOutput || hasFlag(commandArgs, name: "--json") {
            print(jsonString([
                "valid": report.isValid,
                "name": report.manifest?.name as Any,
                "findings": report.findings.map { finding in
                    [
                        "severity": finding.severity.rawValue,
                        "code": finding.code,
                        "message": finding.message,
                        "path": finding.path as Any,
                    ]
                },
            ]))
        } else {
            for finding in report.findings.sorted(by: { $0.severity > $1.severity }) {
                print("\(finding.severity.rawValue): [\(finding.code)] \(finding.message)")
            }
            if report.isValid {
                print("OK \(report.manifest?.name ?? "") is a valid orchestration template")
            }
        }
        if !report.isValid {
            throw CLIError(message: "orchestration validate found \(report.errors.count) error(s)")
        }
    }

    // MARK: - install / update / configure

    private func runOrchestrationInstall(commandArgs: [String]) throws {
        let (refOpt, rem0) = parseOption(commandArgs, name: "--ref")
        let (paramValues, rem1) = parseRepeatedOption(rem0, name: "--param")
        let force = hasFlag(rem1, name: "--force")
        let remaining = rem1.filter { $0 != "--force" }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration install: unknown flag '\(unknown)'")
        }
        guard let sourceArgument = remaining.first, !sourceArgument.isEmpty else {
            throw CLIError(message: "orchestration install requires <git-url-or-path>")
        }

        var source = OrchestrationInstallSource.detect(from: sourceArgument)
        switch source {
        case .localPath(let path):
            source = .localPath(resolvePath(path))
        case .git(let url, _, _):
            source = .git(url: url, reference: refOpt, commit: nil)
        }

        let store = OrchestrationStore()
        let outcome: OrchestrationStore.InstallOutcome
        do {
            outcome = try store.install(source: source, force: force)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        let installed = outcome.installed
        print("Installed \(installed.manifest.name) \(installed.manifest.version) -> \(store.installDirectory(for: installed.manifest.name))")
        for warning in outcome.warnings {
            print("warning: [\(warning.code)] \(warning.message)")
        }
        try orchestrationApplyParameters(
            store: store,
            name: installed.manifest.name,
            manifest: installed.manifest,
            provided: paramValues,
            interviewUnanswered: true
        )
        print("Run it with: cmux orchestration run \(installed.manifest.name) --task \"<task>\"")
    }

    private func runOrchestrationUpdate(commandArgs: [String]) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration update: unknown flag '\(unknown)'")
        }
        guard let name = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "orchestration update requires <name>")
        }
        let store = OrchestrationStore()
        let outcome: OrchestrationStore.InstallOutcome
        do {
            outcome = try store.update(name: name)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        print("Updated \(name) to \(outcome.installed.manifest.version) from \(outcome.installed.record.source.displayName)")
        for warning in outcome.warnings {
            print("warning: [\(warning.code)] \(warning.message)")
        }
        print("Trust confirmation was reset; the next run re-shows the template's scripts and agent commands.")
        try orchestrationApplyParameters(
            store: store,
            name: name,
            manifest: outcome.installed.manifest,
            provided: [],
            interviewUnanswered: true
        )
    }

    private func runOrchestrationConfigure(commandArgs: [String]) throws {
        let (paramValues, remaining) = parseRepeatedOption(commandArgs, name: "--param")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration configure: unknown flag '\(unknown)'")
        }
        guard let name = remaining.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "orchestration configure requires <name>")
        }
        let store = OrchestrationStore()
        let installation: InstalledOrchestration
        do {
            installation = try store.installed(named: name)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        try orchestrationApplyParameters(
            store: store,
            name: name,
            manifest: installation.manifest,
            provided: paramValues,
            interviewUnanswered: paramValues.isEmpty
        )
        print("OK parameters saved for \(name)")
    }

    // MARK: - list / info / remove

    private func runOrchestrationList(commandArgs: [String], jsonOutput: Bool) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "orchestration list: unknown flag '\(unknown)'")
        }
        let store = OrchestrationStore()
        let installations: [InstalledOrchestration]
        do {
            installations = try store.list()
        } catch {
            throw CLIError(message: String(describing: error))
        }
        if jsonOutput || hasFlag(commandArgs, name: "--json") {
            print(jsonString([
                "orchestrations": installations.map { orchestrationInfoObject($0, store: store) },
            ]))
            return
        }
        if installations.isEmpty {
            print("No orchestrations installed. Try: cmux orchestration install <git-url-or-path>")
            return
        }
        print("NAME\tVERSION\tSUBSTRATE\tAGENTS\tTRUSTED\tDESCRIPTION")
        for installation in installations {
            let manifest = installation.manifest
            let trusted = installation.record.trustConfirmedAt != nil ? "yes" : "no"
            print("\(manifest.name)\t\(manifest.version)\t\(manifest.substrate.kind.rawValue)\t\(manifest.agents.map(\.id).joined(separator: ","))\t\(trusted)\t\(manifest.description)")
        }
    }

    private func runOrchestrationInfo(commandArgs: [String], jsonOutput: Bool) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "orchestration info: unknown flag '\(unknown)'")
        }
        guard let name = commandArgs.first(where: { !$0.hasPrefix("--") })?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw CLIError(message: "orchestration info requires <name>")
        }
        let store = OrchestrationStore()
        let installation: InstalledOrchestration
        do {
            installation = try store.installed(named: name)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        if jsonOutput || hasFlag(commandArgs, name: "--json") {
            print(jsonString(orchestrationInfoObject(installation, store: store)))
            return
        }
        let manifest = installation.manifest
        let record = installation.record
        print("\(manifest.name) \(manifest.version) — \(manifest.description)")
        if let author = manifest.author { print("Author: \(author)") }
        print("Source: \(record.source.displayName)")
        print("Substrate: \(manifest.substrate.kind.rawValue)")
        if !manifest.substrate.scriptPaths.isEmpty {
            print("Scripts: \(manifest.substrate.scriptPaths.joined(separator: ", "))")
        }
        print("Trust confirmed: \(record.trustConfirmedAt != nil ? "yes" : "no (first run will ask)")")
        print("Agents:")
        for agent in manifest.agents {
            print("  \(agent.id): \(agent.command)")
        }
        if !manifest.parameters.isEmpty {
            print("Parameters:")
            for parameter in manifest.parameters {
                let value = record.resolvedParameters[parameter.key].map { " = \($0.description)" } ?? " (unanswered)"
                print("  \(parameter.key) [\(parameter.type.rawValue)]\(value)")
            }
        }
        if let steps = manifest.steps, !steps.isEmpty {
            print("Steps: \(steps.map(\.id).joined(separator: " -> "))")
        }
        print("Template: \(installation.templateDirectory)")
    }

    private func runOrchestrationRemove(commandArgs: [String]) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "orchestration remove: unknown flag '\(unknown)'")
        }
        guard let name = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "orchestration remove requires <name>")
        }
        do {
            try OrchestrationStore().remove(name: name)
        } catch {
            throw CLIError(message: String(describing: error))
        }
        print("Removed \(name)")
    }

    // MARK: - Parameter interview

    /// Applies `--param k=v` values, then interviews interactively for any
    /// still-unanswered parameters (TTY only). Values live per-install on
    /// this machine, never in the template.
    func orchestrationApplyParameters(
        store: OrchestrationStore,
        name: String,
        manifest: OrchestrationManifest,
        provided: [String],
        interviewUnanswered: Bool
    ) throws {
        var values: [String: OrchestrationParameterValue] = [:]
        for pair in provided {
            guard let equals = pair.firstIndex(of: "=") else {
                throw CLIError(message: "--param expects key=value, got '\(pair)'")
            }
            let key = String(pair[..<equals])
            let raw = String(pair[pair.index(after: equals)...])
            switch OrchestrationParameterResolution.coerce(overrides: [key: raw], manifest: manifest) {
            case .success(let coerced):
                values.merge(coerced) { _, new in new }
            case .failure(let problem):
                throw CLIError(message: "Parameter '\(problem.key)' \(problem.reason)")
            }
        }
        if !values.isEmpty {
            _ = try? OrchestrationStore().setResolvedParameters(name: name, values: values)
        }

        guard interviewUnanswered else { return }
        let installation: InstalledOrchestration
        do {
            installation = try store.installed(named: name)
        } catch {
            return
        }
        let unanswered = store.unanswered(manifest: installation.manifest, record: installation.record)
        guard !unanswered.isEmpty else { return }
        guard isatty(fileno(stdin)) != 0 else {
            print("Unanswered parameter(s): \(unanswered.map(\.key).joined(separator: ", ")).")
            print("Answer them with: cmux orchestration configure \(name) --param <key>=<value>")
            return
        }
        var answers: [String: OrchestrationParameterValue] = [:]
        for parameter in unanswered {
            if let answer = orchestrationAskParameter(parameter) {
                answers[parameter.key] = answer
            }
        }
        if !answers.isEmpty {
            _ = try? store.setResolvedParameters(name: name, values: answers)
        }
    }

    private func orchestrationAskParameter(_ parameter: OrchestrationParameter) -> OrchestrationParameterValue? {
        var hint = parameter.type.rawValue
        if parameter.type == .choice, let choices = parameter.choices {
            hint = choices.joined(separator: "|")
        }
        for _ in 0..<3 {
            print("\(parameter.prompt) [\(hint)]: ", terminator: "")
            guard let line = readLine() else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            switch parameter.coerce(trimmed) {
            case .success(let value):
                return value
            case .failure(let problem):
                print("  \(problem.reason)")
            }
        }
        return nil
    }

    func orchestrationInfoObject(
        _ installation: InstalledOrchestration,
        store: OrchestrationStore
    ) -> [String: Any] {
        let manifest = installation.manifest
        let record = installation.record
        return [
            "name": manifest.name,
            "version": manifest.version,
            "description": manifest.description,
            "author": manifest.author as Any,
            "substrate": manifest.substrate.kind.rawValue,
            "scripts": manifest.substrate.scriptPaths,
            "agents": manifest.agents.map { ["id": $0.id, "command": $0.command] },
            "source": record.source.displayName,
            "trust_confirmed": record.trustConfirmedAt != nil,
            "template_directory": installation.templateDirectory,
            "parameters": manifest.parameters.map { parameter in
                [
                    "key": parameter.key,
                    "prompt": parameter.prompt,
                    "type": parameter.type.rawValue,
                    "answered": record.resolvedParameters[parameter.key] != nil,
                ]
            },
            "unanswered_parameters": store.unanswered(manifest: manifest, record: record).map(\.key),
        ]
    }
}
