import CmuxSettings
import Foundation

struct BrowserWebExtensionReconciliationPlanner {
    struct LoadedEntry: Equatable {
        let id: String
        let standardizedPath: String
    }

    struct Plan: Equatable {
        let desiredEntries: [BrowserWebExtensionEntry]
        let unloadEntryIDs: [String]
        let loadEntries: [BrowserWebExtensionEntry]
    }

    func plan(
        settingsEntries: [BrowserWebExtensionEntry],
        environmentPaths: [String],
        loadedEntries: [LoadedEntry]
    ) -> Plan {
        let loadedByID = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.id, $0) })
        let desiredEntries = desired(settingsEntries: settingsEntries, environmentPaths: environmentPaths)
        let desiredByID = Dictionary(uniqueKeysWithValues: desiredEntries.map { ($0.id, $0) })

        let unloadEntryIDs = loadedEntries
            .filter { loaded in
                guard let desired = desiredByID[loaded.id] else { return true }
                return Self.standardizedPath(desired.path) != loaded.standardizedPath
            }
            .map(\.id)
            .sorted()

        let loadEntries = desiredEntries.filter { entry in
            guard let loaded = loadedByID[entry.id] else { return true }
            return loaded.standardizedPath != Self.standardizedPath(entry.path)
        }

        return Plan(
            desiredEntries: desiredEntries,
            unloadEntryIDs: unloadEntryIDs,
            loadEntries: loadEntries
        )
    }

    static func standardizedPath(_ path: String) -> String {
        BrowserWebExtensionEntry.standardizedPath(path)
    }

    static func standardizedResourceRootPath(for entry: BrowserWebExtensionEntry) -> String {
        entry.standardizedResourceRootPath
    }

    static func standardizedResourceRootPath(forEnvironmentPath path: String) -> String {
        let standardizedPath = BrowserWebExtensionEntry.standardizedPath(path)
        let kind: BrowserWebExtensionEntry.Kind = URL(fileURLWithPath: standardizedPath).pathExtension == "appex"
            ? .safariAppExtension
            : .unpackedDirectory
        return BrowserWebExtensionEntry.standardizedResourceRootPath(for: kind, path: path)
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
                kind: path.hasSuffix(".appex") ? .safariAppExtension : .unpackedDirectory,
                path: path,
                enabled: true
            ))
        }

        return desired
    }
}
