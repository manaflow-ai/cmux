public import Foundation

/// Failure modes surfaced by the store, with CLI-ready messages.
public enum OrchestrationStoreError: Error, Sendable, Hashable, CustomStringConvertible {
    case notInstalled(String)
    case alreadyInstalled(String)
    case invalidTemplate(name: String?, errors: [String])
    case corruptInstall(name: String, detail: String)
    case sourceUnavailable(String)

    public var description: String {
        switch self {
        case .notInstalled(let name):
            return "No orchestration named '\(name)' is installed"
        case .alreadyInstalled(let name):
            return "Orchestration '\(name)' is already installed (use --force to replace it)"
        case .invalidTemplate(let name, let errors):
            let header = name.map { "Template '\($0)' failed validation:" } ?? "Template failed validation:"
            return ([header] + errors.map { "  - \($0)" }).joined(separator: "\n")
        case .corruptInstall(let name, let detail):
            return "Installed orchestration '\(name)' is corrupt: \(detail)"
        case .sourceUnavailable(let detail):
            return detail
        }
    }
}

/// Manages installed orchestration templates under
/// `~/.cmuxterm/orchestrations/`.
///
/// On-disk layout per install:
///
///     ~/.cmuxterm/orchestrations/<name>/
///       template/      pristine copy or clone of the template
///       install.json   source, install time, resolved parameters, trust
///
/// Trust model, enforced here: installation copies/clones files and parses
/// JSON — it never executes anything from the template. The only external
/// process the store spawns is `git` for git sources.
public struct OrchestrationStore: Sendable {
    public let rootDirectory: String

    private let fileSystem: any OrchestrationFileSystem
    private let gitClient: any OrchestrationGitClient
    private let validator: OrchestrationValidator
    private let now: @Sendable () -> Date

    public static func defaultRootDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
        homeDirectory + "/.cmuxterm/orchestrations"
    }

    public init(
        rootDirectory: String = OrchestrationStore.defaultRootDirectory(),
        fileSystem: any OrchestrationFileSystem = DefaultOrchestrationFileSystem(),
        gitClient: any OrchestrationGitClient = DefaultOrchestrationGitClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory
        self.fileSystem = fileSystem
        self.gitClient = gitClient
        self.validator = OrchestrationValidator(fileSystem: fileSystem)
        self.now = now
    }

    // MARK: - Paths

    public func installDirectory(for name: String) -> String {
        rootDirectory + "/" + name
    }

    public func templateDirectory(for name: String) -> String {
        installDirectory(for: name) + "/template"
    }

    private func recordPath(for name: String) -> String {
        installDirectory(for: name) + "/" + OrchestrationInstallRecord.fileName
    }

    // MARK: - Install

    public struct InstallOutcome: Sendable {
        public var installed: InstalledOrchestration
        public var warnings: [OrchestrationValidationFinding]
        /// Parameters that still need answers before the first run.
        public var unansweredParameters: [OrchestrationParameter]
    }

    /// Installs from a git URL or local directory. The source is fetched
    /// into a staging directory, validated (no errors allowed), and only
    /// then moved into place. Nothing from the template is executed.
    public func install(
        source: OrchestrationInstallSource,
        force: Bool = false
    ) throws -> InstallOutcome {
        try ensureRootExists()
        let stagingPath = rootDirectory + "/.staging-" + UUID().uuidString
        defer { try? fileSystem.removeItem(atPath: stagingPath) }

        var resolvedSource = source
        switch source {
        case .git(let url, let reference, _):
            let commit: String?
            do {
                commit = try gitClient.clone(url: url, reference: reference, toPath: stagingPath)
            } catch {
                throw OrchestrationStoreError.sourceUnavailable(
                    "Could not clone '\(url)': \(String(describing: error))"
                )
            }
            resolvedSource = .git(url: url, reference: reference, commit: commit)
        case .localPath(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            guard fileSystem.directoryExists(atPath: expanded) else {
                throw OrchestrationStoreError.sourceUnavailable("Not a directory: \(path)")
            }
            try fileSystem.copyItem(atPath: expanded, toPath: stagingPath)
            resolvedSource = .localPath(expanded)
        }

        let report = validator.validate(templateDirectory: stagingPath)
        guard let manifest = report.manifest, report.isValid else {
            throw OrchestrationStoreError.invalidTemplate(
                name: report.manifest?.name,
                errors: report.errors.map(\.message)
            )
        }

        let installPath = installDirectory(for: manifest.name)
        if fileSystem.directoryExists(atPath: installPath) {
            guard force else {
                throw OrchestrationStoreError.alreadyInstalled(manifest.name)
            }
            try fileSystem.removeItem(atPath: installPath)
        }

        try fileSystem.createDirectory(atPath: installPath)
        try fileSystem.copyItem(atPath: stagingPath, toPath: templateDirectory(for: manifest.name))

        var record = OrchestrationInstallRecord(
            name: manifest.name,
            source: resolvedSource,
            installedAt: now(),
            templateVersion: manifest.version
        )
        applyParameterDefaults(manifest: manifest, to: &record)
        try writeRecord(record, for: manifest.name)

        return InstallOutcome(
            installed: InstalledOrchestration(
                manifest: manifest,
                record: record,
                templateDirectory: templateDirectory(for: manifest.name)
            ),
            warnings: report.warnings,
            unansweredParameters: unanswered(manifest: manifest, record: record)
        )
    }

    /// Re-fetches an installed template from its recorded source, keeping
    /// resolved parameters but resetting trust confirmation (the template's
    /// scripts/commands may have changed).
    public func update(name: String) throws -> InstallOutcome {
        let existing = try installed(named: name)
        let stagingPath = rootDirectory + "/.staging-" + UUID().uuidString
        defer { try? fileSystem.removeItem(atPath: stagingPath) }

        var refreshedSource = existing.record.source
        switch existing.record.source {
        case .git(let url, let reference, _):
            let commit: String?
            do {
                commit = try gitClient.clone(url: url, reference: reference, toPath: stagingPath)
            } catch {
                throw OrchestrationStoreError.sourceUnavailable(
                    "Could not clone '\(url)': \(String(describing: error))"
                )
            }
            refreshedSource = .git(url: url, reference: reference, commit: commit)
        case .localPath(let path):
            guard fileSystem.directoryExists(atPath: path) else {
                throw OrchestrationStoreError.sourceUnavailable(
                    "Original source directory no longer exists: \(path)"
                )
            }
            try fileSystem.copyItem(atPath: path, toPath: stagingPath)
        }

        let report = validator.validate(templateDirectory: stagingPath)
        guard let manifest = report.manifest, report.isValid else {
            throw OrchestrationStoreError.invalidTemplate(
                name: report.manifest?.name,
                errors: report.errors.map(\.message)
            )
        }
        guard manifest.name == name else {
            throw OrchestrationStoreError.invalidTemplate(
                name: manifest.name,
                errors: ["Updated template renamed itself from '\(name)' to '\(manifest.name)'; install it as a new orchestration instead"]
            )
        }

        let templatePath = templateDirectory(for: name)
        if fileSystem.directoryExists(atPath: templatePath) {
            try fileSystem.removeItem(atPath: templatePath)
        }
        try fileSystem.copyItem(atPath: stagingPath, toPath: templatePath)

        var record = existing.record
        record.source = refreshedSource
        record.updatedAt = now()
        record.templateVersion = manifest.version
        record.trustConfirmedAt = nil
        record.resolvedParameters = record.resolvedParameters.filter { key, _ in
            manifest.parameters.contains { $0.key == key }
        }
        applyParameterDefaults(manifest: manifest, to: &record)
        try writeRecord(record, for: name)

        return InstallOutcome(
            installed: InstalledOrchestration(
                manifest: manifest,
                record: record,
                templateDirectory: templatePath
            ),
            warnings: report.warnings,
            unansweredParameters: unanswered(manifest: manifest, record: record)
        )
    }

    // MARK: - Query

    public func list() throws -> [InstalledOrchestration] {
        guard fileSystem.directoryExists(atPath: rootDirectory) else { return [] }
        let entries = try fileSystem.contentsOfDirectory(atPath: rootDirectory)
        var results: [InstalledOrchestration] = []
        for entry in entries.sorted() {
            guard !entry.hasPrefix("."),
                  fileSystem.directoryExists(atPath: installDirectory(for: entry)),
                  fileSystem.fileExists(atPath: recordPath(for: entry))
            else { continue }
            results.append(try installed(named: entry))
        }
        return results
    }

    public func installed(named name: String) throws -> InstalledOrchestration {
        let recordPath = recordPath(for: name)
        guard fileSystem.fileExists(atPath: recordPath) else {
            throw OrchestrationStoreError.notInstalled(name)
        }
        let record: OrchestrationInstallRecord
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            record = try decoder.decode(OrchestrationInstallRecord.self, from: fileSystem.readData(atPath: recordPath))
        } catch {
            throw OrchestrationStoreError.corruptInstall(name: name, detail: error.localizedDescription)
        }
        let manifestPath = templateDirectory(for: name) + "/" + OrchestrationManifest.manifestFileName
        guard fileSystem.fileExists(atPath: manifestPath) else {
            throw OrchestrationStoreError.corruptInstall(name: name, detail: "template/orchestration.json is missing")
        }
        let manifest: OrchestrationManifest
        do {
            manifest = try OrchestrationManifestParser.parse(data: fileSystem.readData(atPath: manifestPath)).manifest
        } catch {
            throw OrchestrationStoreError.corruptInstall(name: name, detail: String(describing: error))
        }
        return InstalledOrchestration(
            manifest: manifest,
            record: record,
            templateDirectory: templateDirectory(for: name)
        )
    }

    // MARK: - Mutation

    public func remove(name: String) throws {
        let installPath = installDirectory(for: name)
        guard fileSystem.directoryExists(atPath: installPath) else {
            throw OrchestrationStoreError.notInstalled(name)
        }
        try fileSystem.removeItem(atPath: installPath)
    }

    /// Persists interview answers. Values must already be coerced/validated
    /// against the parameter types (see `OrchestrationParameter.coerce`).
    public func setResolvedParameters(
        name: String,
        values: [String: OrchestrationParameterValue]
    ) throws -> OrchestrationInstallRecord {
        var installation = try installed(named: name)
        installation.record.resolvedParameters.merge(values) { _, new in new }
        try writeRecord(installation.record, for: name)
        return installation.record
    }

    /// Marks the trust summary as confirmed by the user.
    public func confirmTrust(name: String) throws -> OrchestrationInstallRecord {
        var installation = try installed(named: name)
        installation.record.trustConfirmedAt = now()
        try writeRecord(installation.record, for: name)
        return installation.record
    }

    public func unanswered(
        manifest: OrchestrationManifest,
        record: OrchestrationInstallRecord
    ) -> [OrchestrationParameter] {
        manifest.parameters.filter { record.resolvedParameters[$0.key] == nil }
    }

    // MARK: - Private

    private func ensureRootExists() throws {
        if !fileSystem.directoryExists(atPath: rootDirectory) {
            try fileSystem.createDirectory(atPath: rootDirectory)
        }
    }

    private func applyParameterDefaults(
        manifest: OrchestrationManifest,
        to record: inout OrchestrationInstallRecord
    ) {
        for parameter in manifest.parameters {
            if record.resolvedParameters[parameter.key] == nil, let defaultValue = parameter.defaultValue {
                record.resolvedParameters[parameter.key] = defaultValue
            }
        }
    }

    private func writeRecord(_ record: OrchestrationInstallRecord, for name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try fileSystem.writeData(try encoder.encode(record), atPath: recordPath(for: name))
    }
}
