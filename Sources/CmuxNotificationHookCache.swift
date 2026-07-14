import Foundation

/// Resolves per-directory notification hooks on a background actor. Cache
/// entries are invalidated by both hierarchy changes (new/removed config
/// files) and file metadata changes, so notification delivery never parses
/// cmux.json on the Ghostty callback thread or main actor.
actor CmuxNotificationHookCache {
    private struct Key: Hashable {
        let directory: String?
        let globalConfigPath: String
    }

    private struct FileFingerprint: Equatable {
        let path: String
        let exists: Bool
        let fileSize: UInt64
        let modificationDate: Date?
        let fileIdentifier: UInt64?
    }

    private struct Entry {
        let fingerprints: [FileFingerprint]
        let hooks: [CmuxResolvedNotificationHook]
    }

    private struct ParsedConfig {
        let fingerprint: FileFingerprint
        let config: CmuxConfigFile?
    }

    private let fileManager: FileManager
    private var entries: [Key: Entry] = [:]
    private var parsedConfigs: [String: ParsedConfig] = [:]
    private(set) var parseCount = 0
    private(set) var hitCount = 0

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func hooks(
        startingFrom directory: String?,
        globalConfigPath: String?
    ) -> [CmuxResolvedNotificationHook] {
        guard let globalConfigPath, !globalConfigPath.isEmpty else { return [] }
        let normalizedDirectory = normalizedDirectory(directory)
        let normalizedGlobalPath = (globalConfigPath as NSString).standardizingPath
        let key = Key(directory: normalizedDirectory, globalConfigPath: normalizedGlobalPath)
        let localPaths = normalizedDirectory.map { findConfigHierarchy(startingFrom: $0) } ?? []
        let paths = [normalizedGlobalPath] + localPaths
        let fingerprints = paths.map(fingerprint(for:))
        if let entry = entries[key], entry.fingerprints == fingerprints {
            hitCount += 1
            return entry.hooks
        }

        let globalConfig = parsedConfig(for: fingerprints[0])
        let localConfigs = zip(localPaths, fingerprints.dropFirst()).compactMap { path, fingerprint in
            parsedConfig(for: fingerprint).map { (path: path, config: $0) }
        }
        let hooks = resolveHooks(
            globalConfig: globalConfig,
            globalConfigPath: normalizedGlobalPath,
            localConfigs: localConfigs
        )
        entries[key] = Entry(fingerprints: fingerprints, hooks: hooks)
        return hooks
    }

    private func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).standardizingPath
    }

    private func findConfigHierarchy(startingFrom directory: String) -> [String] {
        var current = directory
        var paths: [String] = []
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            if let candidate = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
                paths.append(candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        return paths.reversed()
    }

    private func fingerprint(for path: String) -> FileFingerprint {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return FileFingerprint(
                path: path,
                exists: false,
                fileSize: 0,
                modificationDate: nil,
                fileIdentifier: nil
            )
        }
        return FileFingerprint(
            path: path,
            exists: true,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func parsedConfig(for fingerprint: FileFingerprint) -> CmuxConfigFile? {
        guard fingerprint.exists else {
            parsedConfigs.removeValue(forKey: fingerprint.path)
            return nil
        }
        if let cached = parsedConfigs[fingerprint.path], cached.fingerprint == fingerprint {
            return cached.config
        }
        parseCount += 1
        let config: CmuxConfigFile?
        if let data = fileManager.contents(atPath: fingerprint.path),
           let sanitized = try? JSONCParser.preprocess(data: data) {
            config = try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        } else {
            config = nil
        }
        parsedConfigs[fingerprint.path] = ParsedConfig(fingerprint: fingerprint, config: config)
        return config
    }

    private func resolveHooks(
        globalConfig: CmuxConfigFile?,
        globalConfigPath: String,
        localConfigs: [(path: String, config: CmuxConfigFile)]
    ) -> [CmuxResolvedNotificationHook] {
        var hooks: [CmuxResolvedNotificationHook] = []
        if let definitions = globalConfig?.notifications?.hooks {
            hooks = definitions.compactMap {
                resolvedHook($0, sourcePath: globalConfigPath, globalConfigPath: globalConfigPath)
            }
        }
        for entry in localConfigs {
            guard let notifications = entry.config.notifications else { continue }
            if notifications.hooksMode == .replace { hooks.removeAll() }
            if let definitions = notifications.hooks {
                hooks.append(contentsOf: definitions.compactMap {
                    resolvedHook($0, sourcePath: entry.path, globalConfigPath: globalConfigPath)
                })
            }
        }
        return hooks
    }

    private func resolvedHook(
        _ definition: CmuxNotificationHookDefinition,
        sourcePath: String,
        globalConfigPath: String
    ) -> CmuxResolvedNotificationHook? {
        guard definition.enabled else { return nil }
        let cwd = CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)
        let canonicalSourcePath = canonicalPath(sourcePath)
        let canonicalGlobalPath = canonicalPath(globalConfigPath)
        let trustDescriptor: CmuxActionTrustDescriptor? = canonicalSourcePath == canonicalGlobalPath ? nil :
            CmuxActionTrustDescriptor(
                actionID: definition.id,
                kind: "notificationHook",
                command: definition.command,
                target: "notificationPolicy",
                workspaceCommand: nil,
                configPath: canonicalSourcePath,
                projectRoot: canonicalPath(cwd),
                iconFingerprint: nil
            )
        return CmuxResolvedNotificationHook(
            id: definition.id,
            command: definition.command,
            timeoutSeconds: definition.resolvedTimeoutSeconds,
            sourcePath: sourcePath,
            cwd: cwd,
            trustDescriptor: trustDescriptor
        )
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
