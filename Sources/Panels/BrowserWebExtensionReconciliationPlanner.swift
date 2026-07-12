import CmuxSettings
import Foundation

struct BrowserWebExtensionReconciliationPlanner: Sendable {
    typealias LoadedEntry = BrowserWebExtensionReconciliationLoadedEntry
    typealias UnloadEntry = BrowserWebExtensionReconciliationUnloadEntry
    typealias Plan = BrowserWebExtensionReconciliationPlan

    func plan(
        settingsEntries: [BrowserWebExtensionEntry],
        previousSettingsEntries: [BrowserWebExtensionEntry] = [],
        environmentPaths: [String],
        loadedEntries: [LoadedEntry]
    ) -> Plan {
        let loadedByID = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.id, $0) })
        let desiredEntries = desired(settingsEntries: settingsEntries, environmentPaths: environmentPaths)
        let desiredByID = Dictionary(uniqueKeysWithValues: desiredEntries.map { ($0.id, $0) })
        var configuredResourceRootByID: [String: String] = [:]
        for entry in settingsEntries {
            configuredResourceRootByID[entry.id] = Self.standardizedResourceRootPath(for: entry)
        }

        let unloadEntries = loadedEntries
            .filter { loaded in
                guard let desired = desiredByID[loaded.id] else { return true }
                return Self.standardizedResourceRootPath(for: desired) != loaded.standardizedPath
            }
            .map { loaded in
                UnloadEntry(
                    id: loaded.id,
                    preservePermissionState: configuredResourceRootByID[loaded.id] == loaded.standardizedPath
                )
            }
            .sorted { $0.id < $1.id }

        let loadEntries = desiredEntries.filter { entry in
            guard let loaded = loadedByID[entry.id] else { return true }
            return loaded.standardizedPath != Self.standardizedResourceRootPath(for: entry)
        }

        var seenPermissionStateRemovals = Set<String>()
        let permissionStateRemovalEntries: [BrowserWebExtensionPermissionStateRemoval] =
            previousSettingsEntries.compactMap { previous -> BrowserWebExtensionPermissionStateRemoval? in
                let previousPath = Self.standardizedResourceRootPath(for: previous)
                let currentPath = settingsEntries
                    .first(where: { $0.id == previous.id })
                    .map(Self.standardizedResourceRootPath(for:))
                guard currentPath != previousPath else { return nil }
                let identity = "\(previous.id)\n\(previousPath)"
                guard seenPermissionStateRemovals.insert(identity).inserted else { return nil }
                return BrowserWebExtensionPermissionStateRemoval(
                    id: previous.id,
                    standardizedPath: previousPath
                )
            }.sorted {
                ($0.id, $0.standardizedPath) < ($1.id, $1.standardizedPath)
            }

        return Plan(
            desiredEntries: desiredEntries,
            unloadEntries: unloadEntries,
            loadEntries: loadEntries,
            permissionStateRemovalEntries: permissionStateRemovalEntries
        )
    }

    func rollbackEntriesAfterFailedUnloads(
        settingsEntries: [BrowserWebExtensionEntry],
        failedEntries: [BrowserWebExtensionEntry]
    ) -> [BrowserWebExtensionEntry] {
        var restoredEntries = settingsEntries

        for failedEntry in failedEntries {
            var restoredEntry = failedEntry
            restoredEntry.enabled = true
            let failedResourceRoot = Self.standardizedResourceRootPath(for: restoredEntry)

            for index in restoredEntries.indices
                where restoredEntries[index].id != restoredEntry.id
                    && Self.standardizedResourceRootPath(for: restoredEntries[index]) == failedResourceRoot {
                restoredEntries[index].enabled = false
            }

            if let existingIndex = restoredEntries.firstIndex(where: { $0.id == restoredEntry.id }) {
                restoredEntries[existingIndex] = restoredEntry
            } else {
                restoredEntries.append(restoredEntry)
            }
        }

        return restoredEntries
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).browserWebExtensionStandardizedPath
    }

    static func standardizedResourceRootPath(for entry: BrowserWebExtensionEntry) -> String {
        entry.standardizedResourceRootPath
    }

    static func standardizedResourceRootPath(forEnvironmentPath path: String) -> String {
        kind(forEnvironmentPath: path).standardizedResourceRootPath(for: path)
    }

    private static func kind(forEnvironmentPath path: String) -> BrowserWebExtensionKind {
        let standardizedPath = URL(fileURLWithPath: path).browserWebExtensionStandardizedPath
        return URL(fileURLWithPath: standardizedPath).pathExtension == "appex"
            ? .safariAppExtension
            : .unpackedDirectory
    }

    private func desired(
        settingsEntries: [BrowserWebExtensionEntry],
        environmentPaths: [String]
    ) -> [BrowserWebExtensionEntry] {
        let settingsPaths = Set(settingsEntries.map { Self.standardizedResourceRootPath(for: $0) })
        var seenDesiredPaths = Set<String>()
        var desired: [BrowserWebExtensionEntry] = []
        var desiredIDs = Set<String>()

        for entry in settingsEntries where entry.enabled {
            let standardizedPath = Self.standardizedResourceRootPath(for: entry)
            guard seenDesiredPaths.insert(standardizedPath).inserted else { continue }
            guard desiredIDs.insert(entry.id).inserted else { continue }
            desired.append(entry)
        }

        for path in environmentPaths {
            let standardizedPath = Self.standardizedResourceRootPath(forEnvironmentPath: path)
            guard !settingsPaths.contains(standardizedPath) else { continue }
            guard seenDesiredPaths.insert(standardizedPath).inserted else { continue }
            guard desiredIDs.insert(path).inserted else { continue }
            desired.append(BrowserWebExtensionEntry(
                id: path,
                kind: Self.kind(forEnvironmentPath: path),
                path: path,
                enabled: true
            ))
        }

        return desired
    }
}
