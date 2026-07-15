import CmuxGit
import CmuxSettings
import CryptoKit
import Foundation

struct RepositoryScriptResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(
        directory: String,
        preferences: [RepositoryScriptPreference]
    ) -> RepositoryScriptResolution? {
        guard let repository = GitMetadataService.resolveGitRepository(containing: directory) else {
            return nil
        }
        let commonDirectory = canonical(repository.commonDirectory)
        let identity = RepositoryScriptIdentity(
            id: repositoryID(commonDirectory: commonDirectory),
            workTreeRoot: canonical(repository.workTreeRoot),
            commonDirectory: commonDirectory
        )
        let project = loadProjectScripts(workTreeRoot: identity.workTreeRoot)
        let preference = preferences.first(where: { $0.repositoryID == identity.id })
        if let preference, preference.overridesProjectScripts {
            return RepositoryScriptResolution(
                identity: identity,
                scripts: CmuxRepositoryScriptsDefinition(
                    setup: preference.setup,
                    archive: preference.archive
                ).normalized,
                projectScripts: project.scripts,
                source: .userSettings,
                preference: preference
            )
        }
        let source: RepositoryScriptSource = project.path.map {
            .projectFile(path: $0)
        } ?? .none
        return RepositoryScriptResolution(
            identity: identity,
            scripts: project.scripts,
            projectScripts: project.scripts,
            source: source,
            preference: preference
        )
    }

    func trustDescriptor(for resolution: RepositoryScriptResolution) -> CmuxActionTrustDescriptor? {
        guard !resolution.scripts.isEmpty,
              case .projectFile = resolution.source else { return nil }
        let fingerprintPayload = [
            resolution.setup.map { "setup:\n\($0)" },
            resolution.archive.map { "archive:\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
        return CmuxActionTrustDescriptor(
            actionID: "repository-scripts",
            kind: "repositoryScripts",
            command: fingerprintPayload,
            target: "workspaceLifecycle",
            workspaceCommand: nil,
            // The source path is passed separately for the prompt. Excluding the
            // worktree-specific path keeps trust stable across linked worktrees.
            configPath: nil,
            projectRoot: resolution.identity.commonDirectory,
            iconFingerprint: nil
        )
    }

    func trustDisplayCommand(for resolution: RepositoryScriptResolution) -> String {
        let setupLabel = String(localized: "dialog.repositoryScripts.trust.setupLabel", defaultValue: "Setup")
        let archiveLabel = String(localized: "dialog.repositoryScripts.trust.archiveLabel", defaultValue: "Archive")
        return [
            resolution.setup.map { "\(setupLabel):\n\($0)" },
            resolution.archive.map { "\(archiveLabel):\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    func repositoryID(commonDirectory: String) -> String {
        let value = canonical(commonDirectory)
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadProjectScripts(
        workTreeRoot: String
    ) -> (scripts: CmuxRepositoryScriptsDefinition, path: String?) {
        let candidates = [
            URL(fileURLWithPath: workTreeRoot).appendingPathComponent(".cmux/cmux.json"),
            URL(fileURLWithPath: workTreeRoot).appendingPathComponent("cmux.json"),
        ]
        guard let path = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: path),
              let sanitized = try? JSONCParser.preprocess(data: data),
              let config = try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized) else {
            return (CmuxRepositoryScriptsDefinition(), nil)
        }
        return (config.scripts?.normalized ?? CmuxRepositoryScriptsDefinition(), path.path)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
