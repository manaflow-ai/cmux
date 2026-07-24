import CryptoKit
import Foundation

/// Resolves per-directory notification hooks on a background actor. Cache
/// entries are invalidated by hierarchy or content changes, so notification
/// delivery never parses cmux.json on the Ghostty callback thread or main actor.
actor CmuxNotificationHookCache {
    private let fileManager: FileManager
    private let maximumEntryCount: Int
    private var entries: [CmuxNotificationHookCacheKey: CmuxNotificationHookCacheEntry] = [:]
    private var parsedConfigs: [String: CmuxNotificationHookParsedConfig] = [:]
    private var accessSequence: UInt64 = 0
    private(set) var parseCount = 0
    private(set) var hitCount = 0

    init(fileManager: FileManager = .default, maximumEntryCount: Int = 128) {
        self.fileManager = fileManager
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func hooks(
        startingFrom directory: String?,
        globalConfigPath: String?
    ) -> [CmuxResolvedNotificationHook] {
        guard let globalConfigPath, !globalConfigPath.isEmpty else { return [] }
        let normalizedDirectory = normalizedDirectory(directory)
        let normalizedGlobalPath = (globalConfigPath as NSString).standardizingPath
        let key = CmuxNotificationHookCacheKey(directory: normalizedDirectory, globalConfigPath: normalizedGlobalPath)
        let localPaths = normalizedDirectory.map { findConfigHierarchy(startingFrom: $0) } ?? []
        let paths = [normalizedGlobalPath] + localPaths
        let snapshots = paths.map(snapshot(for:))
        let fingerprints = snapshots.map(\.fingerprint)
        let sequence = nextAccessSequence()
        if var entry = entries[key], entry.fingerprints == fingerprints {
            hitCount += 1
            entry.lastAccessSequence = sequence
            entries[key] = entry
            return entry.hooks
        }

        let globalConfig = parsedConfig(for: snapshots[0])
        let localConfigs = zip(localPaths, snapshots.dropFirst()).compactMap { path, snapshot in
            parsedConfig(for: snapshot).map { (path: path, config: $0) }
        }
        let hooks = resolveHooks(
            globalConfig: globalConfig,
            globalConfigPath: normalizedGlobalPath,
            localConfigs: localConfigs
        )
        entries[key] = CmuxNotificationHookCacheEntry(
            fingerprints: fingerprints,
            hooks: hooks,
            lastAccessSequence: sequence
        )
        evictEntriesIfNeeded()
        return hooks
    }

    private func nextAccessSequence() -> UInt64 {
        accessSequence &+= 1
        return accessSequence
    }

    private func evictEntriesIfNeeded() {
        while entries.count > maximumEntryCount,
              let leastRecentlyUsedKey = entries.min(by: {
                  $0.value.lastAccessSequence < $1.value.lastAccessSequence
              })?.key {
            entries.removeValue(forKey: leastRecentlyUsedKey)
        }
        let referencedPaths = Set(entries.values.flatMap { entry in
            entry.fingerprints.lazy.filter(\.exists).map(\.path)
        })
        parsedConfigs = parsedConfigs.filter { referencedPaths.contains($0.key) }
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

    private func snapshot(for path: String) -> CmuxNotificationHookFileSnapshot {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let contents = fileManager.contents(atPath: path)
        let exists = attributes != nil || contents != nil
        let fingerprint = CmuxNotificationHookFileFingerprint(
            path: path,
            exists: exists,
            fileSize: (attributes?[.size] as? NSNumber)?.uint64Value
                ?? UInt64(contents?.count ?? 0),
            modificationDate: attributes?[.modificationDate] as? Date,
            fileIdentifier: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            contentDigest: contents.map { Data(SHA256.hash(data: $0)) }
        )
        return CmuxNotificationHookFileSnapshot(fingerprint: fingerprint, contents: contents)
    }

    private func parsedConfig(for snapshot: CmuxNotificationHookFileSnapshot) -> CmuxConfigFile? {
        let fingerprint = snapshot.fingerprint
        guard fingerprint.exists else {
            parsedConfigs.removeValue(forKey: fingerprint.path)
            return nil
        }
        if let cached = parsedConfigs[fingerprint.path], cached.fingerprint == fingerprint {
            return cached.config
        }
        parseCount += 1
        let config: CmuxConfigFile?
        if let contents = snapshot.contents,
           let sanitized = try? JSONCParser.preprocess(data: contents) {
            config = try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        } else {
            config = nil
        }
        parsedConfigs[fingerprint.path] = CmuxNotificationHookParsedConfig(fingerprint: fingerprint, config: config)
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
