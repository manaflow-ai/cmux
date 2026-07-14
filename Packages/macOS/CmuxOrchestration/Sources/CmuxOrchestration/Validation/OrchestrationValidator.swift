import Foundation

/// One issue found while linting a template directory.
public struct OrchestrationValidationFinding: Sendable, Hashable {
    public enum Severity: String, Sendable, Comparable {
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public var severity: Severity
    /// Stable machine identifier, e.g. `missing-file`, `unknown-agent`.
    public var code: String
    public var message: String
    /// Template-relative path the finding refers to, when applicable.
    public var path: String?

    public init(severity: Severity, code: String, message: String, path: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }
}

/// The result of validating a template directory.
public struct OrchestrationValidationReport: Sendable {
    public var manifest: OrchestrationManifest?
    public var findings: [OrchestrationValidationFinding]

    public var isValid: Bool {
        manifest != nil && !findings.contains { $0.severity == .error }
    }

    public var errors: [OrchestrationValidationFinding] {
        findings.filter { $0.severity == .error }
    }

    public var warnings: [OrchestrationValidationFinding] {
        findings.filter { $0.severity == .warning }
    }
}

/// Lints an orchestration template directory: manifest shape, referenced
/// files, placeholder resolvability, script substrate hygiene, and a
/// secret-material scan. Pure logic over the `OrchestrationFileSystem` seam.
public struct OrchestrationValidator: Sendable {
    private let fileSystem: any OrchestrationFileSystem

    public init(fileSystem: any OrchestrationFileSystem = DefaultOrchestrationFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func validate(templateDirectory: String) -> OrchestrationValidationReport {
        var findings: [OrchestrationValidationFinding] = []
        guard fileSystem.directoryExists(atPath: templateDirectory) else {
            findings.append(.init(
                severity: .error,
                code: "missing-template",
                message: "Not a directory: \(templateDirectory)"
            ))
            return OrchestrationValidationReport(manifest: nil, findings: findings)
        }

        let manifestPath = join(templateDirectory, OrchestrationManifest.manifestFileName)
        guard fileSystem.fileExists(atPath: manifestPath) else {
            findings.append(.init(
                severity: .error,
                code: "missing-manifest",
                message: "Missing \(OrchestrationManifest.manifestFileName) at the template root",
                path: OrchestrationManifest.manifestFileName
            ))
            return OrchestrationValidationReport(manifest: nil, findings: findings)
        }

        let manifest: OrchestrationManifest
        do {
            let data = try fileSystem.readData(atPath: manifestPath)
            let output = try OrchestrationManifest.parse(data: data)
            manifest = output.manifest
            for key in output.unknownKeys {
                findings.append(.init(
                    severity: .warning,
                    code: "unknown-key",
                    message: "Unknown top-level key '\(key)' in orchestration.json (typo?)",
                    path: OrchestrationManifest.manifestFileName
                ))
            }
        } catch {
            findings.append(.init(
                severity: .error,
                code: "invalid-manifest",
                message: String(describing: error),
                path: OrchestrationManifest.manifestFileName
            ))
            return OrchestrationValidationReport(manifest: nil, findings: findings)
        }

        validateIdentity(manifest, into: &findings)
        validateParameters(manifest, into: &findings)
        validateAgents(manifest, into: &findings)
        validateSteps(manifest, in: templateDirectory, into: &findings)
        validateReferencedFiles(manifest, in: templateDirectory, into: &findings)
        validateSubstrate(manifest, in: templateDirectory, into: &findings)
        validatePlaceholders(manifest, in: templateDirectory, into: &findings)
        scanForSecrets(manifest, in: templateDirectory, into: &findings)

        return OrchestrationValidationReport(manifest: manifest, findings: findings)
    }

    // MARK: - Individual checks

    private func validateIdentity(
        _ manifest: OrchestrationManifest,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        if !OrchestrationManifest.isValidName(manifest.name) {
            findings.append(.init(
                severity: .error,
                code: "invalid-name",
                message: "Template name '\(manifest.name)' must be a lowercase slug (letters, digits, hyphens)"
            ))
        }
        if OrchestrationVersion(string: manifest.version) == nil {
            findings.append(.init(
                severity: .error,
                code: "invalid-version",
                message: "Template version '\(manifest.version)' is not a dotted numeric version (X[.Y[.Z]])"
            ))
        }
        if let minCmuxVersion = manifest.minCmuxVersion, OrchestrationVersion(string: minCmuxVersion) == nil {
            findings.append(.init(
                severity: .error,
                code: "invalid-min-cmux-version",
                message: "minCmuxVersion '\(minCmuxVersion)' is not a dotted numeric version (X[.Y[.Z]])"
            ))
        }
        if manifest.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.init(
                severity: .warning,
                code: "empty-description",
                message: "Template description is empty"
            ))
        }
    }

    private func validateParameters(
        _ manifest: OrchestrationManifest,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        var seenKeys: Set<String> = []
        for parameter in manifest.parameters {
            if !OrchestrationParameter.isValidKey(parameter.key) {
                findings.append(.init(
                    severity: .error,
                    code: "invalid-parameter-key",
                    message: "Parameter key '\(parameter.key)' must be lowercase letters, digits, underscores, starting with a letter"
                ))
            }
            if !seenKeys.insert(parameter.key).inserted {
                findings.append(.init(
                    severity: .error,
                    code: "duplicate-parameter",
                    message: "Duplicate parameter key '\(parameter.key)'"
                ))
            }
            let reserved = OrchestrationPlaceholders.builtins.union(OrchestrationPlaceholders.commandOnlyBuiltins)
            if reserved.contains(parameter.key) {
                findings.append(.init(
                    severity: .error,
                    code: "reserved-parameter",
                    message: "Parameter key '\(parameter.key)' shadows a built-in placeholder"
                ))
            }
            if parameter.type == .choice, (parameter.choices ?? []).isEmpty {
                findings.append(.init(
                    severity: .error,
                    code: "empty-choices",
                    message: "Parameter '\(parameter.key)' is a choice but lists no choices"
                ))
            }
            if let defaultValue = parameter.defaultValue,
               case .failure(let problem) = parameter.coerce(defaultValue.description) {
                findings.append(.init(
                    severity: .error,
                    code: "invalid-default",
                    message: "Parameter '\(parameter.key)' default does not match its type: \(problem.reason)"
                ))
            }
        }
    }

    private func validateAgents(
        _ manifest: OrchestrationManifest,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        if manifest.agents.isEmpty {
            findings.append(.init(
                severity: .error,
                code: "no-agents",
                message: "Template declares no agents; at least one agent command is required"
            ))
        }
        var seenIDs: Set<String> = []
        for agent in manifest.agents {
            if !seenIDs.insert(agent.id).inserted {
                findings.append(.init(
                    severity: .error,
                    code: "duplicate-agent",
                    message: "Duplicate agent id '\(agent.id)'"
                ))
            }
            let placeholders = Set(OrchestrationPlaceholders().scan(agent.command))
            if placeholders.isDisjoint(with: ["prompt", "prompt_file"]) {
                findings.append(.init(
                    severity: .warning,
                    code: "command-without-prompt",
                    message: "Agent '\(agent.id)' command references neither {{prompt}} nor {{prompt_file}}"
                ))
            }
        }
        if let defaultAgent = manifest.defaultAgent, manifest.agent(withID: defaultAgent) == nil {
            findings.append(.init(
                severity: .error,
                code: "unknown-default-agent",
                message: "defaultAgent '\(defaultAgent)' is not a declared agent"
            ))
        }
    }

    private func validateSteps(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        guard let steps = manifest.steps else {
            if manifest.prompt == nil {
                findings.append(.init(
                    severity: .error,
                    code: "no-prompt",
                    message: "Template has neither a top-level 'prompt' nor 'steps'; a run would have nothing to send"
                ))
            }
            return
        }
        if steps.isEmpty {
            findings.append(.init(
                severity: .error,
                code: "empty-steps",
                message: "'steps' is present but empty; omit it or declare at least one step"
            ))
        }
        var seenIDs: Set<String> = []
        for step in steps {
            if !seenIDs.insert(step.id).inserted {
                findings.append(.init(
                    severity: .error,
                    code: "duplicate-step",
                    message: "Duplicate step id '\(step.id)'"
                ))
            }
            if manifest.agent(withID: step.agent) == nil {
                findings.append(.init(
                    severity: .error,
                    code: "unknown-agent",
                    message: "Step '\(step.id)' references undeclared agent '\(step.agent)'"
                ))
            }
        }
    }

    private func validateReferencedFiles(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        var references: [(path: String, role: String)] = []
        if let prompt = manifest.prompt { references.append((prompt, "prompt")) }
        for step in manifest.steps ?? [] { references.append((step.prompt, "step '\(step.id)' prompt")) }
        if let layout = manifest.layout { references.append((layout, "layout")) }
        if let workflow = manifest.workflow { references.append((workflow, "workflow")) }
        for instruction in manifest.instructions ?? [] { references.append((instruction, "instructions")) }

        for reference in references {
            if let problem = relativePathProblem(reference.path) {
                findings.append(.init(
                    severity: .error,
                    code: "invalid-path",
                    message: "\(reference.role) path '\(reference.path)' \(problem)",
                    path: reference.path
                ))
                continue
            }
            if !fileSystem.fileExists(atPath: join(templateDirectory, reference.path)) {
                findings.append(.init(
                    severity: .error,
                    code: "missing-file",
                    message: "\(reference.role) file '\(reference.path)' does not exist in the template",
                    path: reference.path
                ))
            }
        }

        if manifest.layout != nil, let layout = manifest.layout,
           fileSystem.fileExists(atPath: join(templateDirectory, layout)) {
            let data = (try? fileSystem.readData(atPath: join(templateDirectory, layout))) ?? Data()
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                findings.append(.init(
                    severity: .error,
                    code: "invalid-layout",
                    message: "Layout file '\(layout)' is not valid JSON",
                    path: layout
                ))
            }
        }
    }

    private func validateSubstrate(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        switch manifest.substrate {
        case .worktree:
            break
        case .clonePool(let poolSize):
            if let poolSize, poolSize < 1 {
                findings.append(.init(
                    severity: .error,
                    code: "invalid-pool-size",
                    message: "clone-pool poolSize must be at least 1"
                ))
            }
        case .script:
            for scriptPath in manifest.substrate.scriptPaths {
                if let problem = relativePathProblem(scriptPath) {
                    findings.append(.init(
                        severity: .error,
                        code: "invalid-path",
                        message: "substrate script path '\(scriptPath)' \(problem)",
                        path: scriptPath
                    ))
                    continue
                }
                let absolute = join(templateDirectory, scriptPath)
                if !fileSystem.fileExists(atPath: absolute) {
                    findings.append(.init(
                        severity: .error,
                        code: "missing-script",
                        message: "substrate script '\(scriptPath)' does not exist in the template",
                        path: scriptPath
                    ))
                } else if !fileSystem.isExecutableFile(atPath: absolute) {
                    findings.append(.init(
                        severity: .warning,
                        code: "script-not-executable",
                        message: "substrate script '\(scriptPath)' is not executable (chmod +x)",
                        path: scriptPath
                    ))
                }
            }
        }
    }

    private func validatePlaceholders(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        let parameterKeys = Set(manifest.parameters.map(\.key))
        let promptAllowed = OrchestrationPlaceholders.builtins.union(parameterKeys)
        let commandAllowed = promptAllowed.union(OrchestrationPlaceholders.commandOnlyBuiltins)

        var promptPaths: [String] = []
        if let prompt = manifest.prompt { promptPaths.append(prompt) }
        promptPaths.append(contentsOf: (manifest.steps ?? []).map(\.prompt))

        for promptPath in promptPaths {
            let absolute = join(templateDirectory, promptPath)
            guard fileSystem.fileExists(atPath: absolute),
                  let data = try? fileSystem.readData(atPath: absolute),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for name in OrchestrationPlaceholders().scan(text) where !promptAllowed.contains(name) {
                findings.append(.init(
                    severity: .error,
                    code: "unknown-placeholder",
                    message: "Prompt '\(promptPath)' references {{\(name)}}, which is neither a built-in nor a parameter",
                    path: promptPath
                ))
            }
        }

        for agent in manifest.agents {
            for name in OrchestrationPlaceholders().scan(agent.command) where !commandAllowed.contains(name) {
                findings.append(.init(
                    severity: .error,
                    code: "unknown-placeholder",
                    message: "Agent '\(agent.id)' command references {{\(name)}}, which is neither a built-in nor a parameter"
                ))
            }
        }
    }

    /// High-confidence secret-material patterns. Templates are shared
    /// artifacts; credentials must stay on the user's machine.
    private static let secretPatterns: [String] = [
        "ghp_",
        "github_pat_",
        "sk-ant-",
        "xoxb-",
        "xoxp-",
        "AKIA",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
    ]

    private func scanForSecrets(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        for relativePath in textFiles(under: templateDirectory) {
            guard let data = try? fileSystem.readData(atPath: join(templateDirectory, relativePath)),
                  data.count < 1_048_576,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for pattern in Self.secretPatterns where text.contains(pattern) {
                findings.append(.init(
                    severity: .error,
                    code: "secret-material",
                    message: "File '\(relativePath)' contains what looks like secret material ('\(pattern)…'); templates must never contain secrets",
                    path: relativePath
                ))
            }
        }
    }

    /// Walks the template (skipping `.git`) and returns relative file paths.
    private func textFiles(under root: String, prefix: String = "", depth: Int = 0) -> [String] {
        guard depth < 6, let entries = try? fileSystem.contentsOfDirectory(atPath: root) else { return [] }
        var results: [String] = []
        for entry in entries.sorted() {
            if entry == ".git" { continue }
            let absolute = join(root, entry)
            let relative = prefix.isEmpty ? entry : "\(prefix)/\(entry)"
            if fileSystem.directoryExists(atPath: absolute) {
                results.append(contentsOf: textFiles(under: absolute, prefix: relative, depth: depth + 1))
            } else {
                results.append(relative)
            }
        }
        return results
    }

    /// Rejects absolute paths and traversal outside the template root.
    private func relativePathProblem(_ path: String) -> String? {
        if path.isEmpty { return "is empty" }
        if path.hasPrefix("/") || path.hasPrefix("~") { return "must be relative to the template root" }
        let components = path.split(separator: "/")
        if components.contains("..") { return "must not contain '..'" }
        return nil
    }

    private func join(_ base: String, _ relative: String) -> String {
        base.hasSuffix("/") ? base + relative : base + "/" + relative
    }
}
