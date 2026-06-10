import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Notification Hook Resolution
extension CmuxConfigStore {
    func notificationHooks(startingFrom directory: String?) -> [CmuxResolvedNotificationHook] {
        let globalConfig = parseConfig(at: globalConfigPath).config
        let localConfigs: [(path: String, config: CmuxConfigFile)]
        if let directory, !directory.isEmpty {
            localConfigs = findCmuxConfigHierarchy(startingFrom: directory).compactMap { path in
                parseConfig(at: path).config.map { (path: path, config: $0) }
            }
        } else {
            localConfigs = []
        }
        return resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localConfigs
        )
    }

    func resolvedLocalNotificationHookPaths(fallbackLocalPath: String?) -> [String] {
        if let searchDirectory = localConfigSearchDirectory {
            var paths = findCmuxConfigHierarchy(startingFrom: searchDirectory)
            if let fallbackLocalPath, !paths.contains(fallbackLocalPath) {
                paths.append(fallbackLocalPath)
            }
            return paths
        }
        return fallbackLocalPath.map { [$0] } ?? []
    }

    func resolveNotificationHooks(
        globalConfig: CmuxConfigFile?,
        localConfigs: [(path: String, config: CmuxConfigFile)]
    ) -> [CmuxResolvedNotificationHook] {
        var hooks: [CmuxResolvedNotificationHook] = []
        if let globalHooks = globalConfig?.notifications?.hooks {
            hooks.append(contentsOf: resolvedNotificationHooks(
                globalHooks,
                sourcePath: globalConfigPath
            ))
        }

        for entry in localConfigs {
            guard let notifications = entry.config.notifications else { continue }
            if notifications.hooksMode == .replace {
                hooks.removeAll()
            }
            if let localHooks = notifications.hooks {
                hooks.append(contentsOf: resolvedNotificationHooks(
                    localHooks,
                    sourcePath: entry.path
                ))
            }
        }
        return hooks
    }

    private func resolvedNotificationHooks(
        _ definitions: [CmuxNotificationHookDefinition],
        sourcePath: String
    ) -> [CmuxResolvedNotificationHook] {
        let cwd = CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)
        let canonicalSourcePath = Self.canonicalPath(sourcePath)
        let canonicalGlobalConfigPath = Self.canonicalPath(globalConfigPath)
        let isGlobalHook = canonicalSourcePath == canonicalGlobalConfigPath
        return definitions.compactMap { definition in
            guard definition.enabled else { return nil }
            let trustDescriptor: CmuxActionTrustDescriptor?
            if isGlobalHook {
                trustDescriptor = nil
            } else {
                trustDescriptor = CmuxActionTrustDescriptor(
                    actionID: definition.id,
                    kind: "notificationHook",
                    command: definition.command,
                    target: "notificationPolicy",
                    workspaceCommand: nil,
                    configPath: canonicalSourcePath,
                    projectRoot: Self.canonicalPath(cwd),
                    iconFingerprint: nil
                )
            }
            return CmuxResolvedNotificationHook(
                id: definition.id,
                command: definition.command,
                timeoutSeconds: definition.resolvedTimeoutSeconds,
                sourcePath: sourcePath,
                cwd: cwd,
                trustDescriptor: trustDescriptor
            )
        }
    }

}
