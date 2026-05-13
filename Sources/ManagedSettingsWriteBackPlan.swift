import Foundation
import os

nonisolated private let managedSettingsWriteBackPlanLog = Logger(subsystem: "com.cmuxterm.app", category: "SettingsFile")

// Plans capture UserDefaults values before background I/O; custom file-backed values resolve during write().
struct ManagedSettingsWriteBackPlan: @unchecked Sendable {
    private let changesBySourcePath: [String: [String: Any]]
    private let customSocketPasswordSources: [(sourcePath: String, jsonPath: String, managedValue: ManagedStringOverride)]

    init(
        changesBySourcePath: [String: [String: Any]],
        customSocketPasswordSources: [(sourcePath: String, jsonPath: String, managedValue: ManagedStringOverride)] = []
    ) {
        self.changesBySourcePath = changesBySourcePath
        self.customSocketPasswordSources = customSocketPasswordSources
    }

    func write(
        fileManager: FileManager,
        loadSocketPassword: () throws -> String? = { try SocketControlPasswordStore.loadPassword() }
    ) throws {
        var resolvedChangesBySourcePath = changesBySourcePath
        collectCustomSocketPasswordEdits(
            changesBySourcePath: &resolvedChangesBySourcePath,
            loadSocketPassword: loadSocketPassword
        )
        for sourcePath in resolvedChangesBySourcePath.keys.sorted() {
            let changesByPath = resolvedChangesBySourcePath[sourcePath] ?? [:]
            let changes = changesByPath.keys.sorted().map { jsonPath in
                (jsonPath: jsonPath, value: changesByPath[jsonPath]!)
            }
            try CmuxSettingsJSONWriter.write(changes, to: sourcePath, fileManager: fileManager)
        }
    }

    private func collectCustomSocketPasswordEdits(
        changesBySourcePath: inout [String: [String: Any]],
        loadSocketPassword: () throws -> String?
    ) {
        for source in customSocketPasswordSources {
            let currentSocketPassword: String?
            do {
                currentSocketPassword = try loadSocketPassword()
            } catch {
                managedSettingsWriteBackPlanLog.error("Failed to read socket password before cmux.json write-back: \(String(describing: error), privacy: .public)")
                continue
            }
            let didChange: Bool
            switch source.managedValue {
            case .set(let value):
                didChange = currentSocketPassword != value
            case .clear:
                didChange = currentSocketPassword != nil
            }
            guard didChange else { continue }
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = currentSocketPassword ?? NSNull()
        }
    }
}

struct ManagedSettingsFileIO: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func write(_ plan: ManagedSettingsWriteBackPlan) throws {
        try plan.write(fileManager: fileManager)
    }
}
