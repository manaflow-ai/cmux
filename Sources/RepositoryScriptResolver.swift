import CmuxGit
import CmuxSettings
import CryptoKit
import Darwin
import Foundation

actor RepositoryScriptResolver {
    private static let maximumProjectConfigBytes = 1_048_576
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

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

    nonisolated func trustDescriptor(
        for resolution: RepositoryScriptResolution
    ) -> CmuxActionTrustDescriptor? {
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

    nonisolated func trustDisplayCommand(for resolution: RepositoryScriptResolution) -> String {
        let setupLabel = String(localized: "dialog.repositoryScripts.trust.setupLabel", defaultValue: "Setup")
        let archiveLabel = String(localized: "dialog.repositoryScripts.trust.archiveLabel", defaultValue: "Archive")
        return [
            resolution.setup.map { "\(setupLabel):\n\($0)" },
            resolution.archive.map { "\(archiveLabel):\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func repositoryID(commonDirectory: String) -> String {
        let value = canonical(commonDirectory)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(value.utf8)) {
            encoded.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            encoded.append(Self.lowercaseHexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func loadProjectScripts(
        workTreeRoot: String
    ) -> (scripts: CmuxRepositoryScriptsDefinition, path: String?) {
        let candidates = [
            URL(fileURLWithPath: workTreeRoot).appendingPathComponent(".cmux/cmux.json"),
            URL(fileURLWithPath: workTreeRoot).appendingPathComponent("cmux.json"),
        ]
        for path in candidates {
            let read = readProjectConfig(at: path)
            guard read.exists else { continue }
            guard let data = read.data,
                  let sanitized = try? JSONCParser.preprocess(data: data),
                  let config = try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized) else {
                return (CmuxRepositoryScriptsDefinition(), nil)
            }
            return (config.scripts?.normalized ?? CmuxRepositoryScriptsDefinition(), path.path)
        }
        return (CmuxRepositoryScriptsDefinition(), nil)
    }

    private func readProjectConfig(at url: URL) -> (exists: Bool, data: Data?) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return (errno != ENOENT && errno != ENOTDIR, nil)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size <= off_t(Self.maximumProjectConfigBytes) else {
            return (true, nil)
        }

        let readLimit = Self.maximumProjectConfigBytes + 1
        var data = Data(count: readLimit)
        var count = 0
        let readSucceeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            while count < readLimit {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: count),
                    readLimit - count
                )
                if result > 0 {
                    count += result
                } else if result == 0 {
                    return true
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        guard readSucceeded, count <= Self.maximumProjectConfigBytes else {
            return (true, nil)
        }
        data.removeSubrange(count..<data.count)
        return (true, data)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
