import Foundation
import os

nonisolated private let managedSettingsWriteBackPlanLog = Logger(subsystem: "com.cmuxterm.app", category: "SettingsFile")

enum ManagedSettingsWriteBackOutcome: Equatable, Sendable {
    case wroteChanges
    case noChanges
}

// Plans capture UserDefaults values before background I/O; custom file-backed values resolve during write().
// Safety: all captured values are immutable JSON-compatible values copied before detached background work runs.
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
        loadSocketPassword: () throws -> String? = { try SocketControlPasswordStore.loadPassword() },
        shouldContinue: ManagedSettingsWriteBackShouldContinue = { true }
    ) async throws -> ManagedSettingsWriteBackOutcome {
        var resolvedChangesBySourcePath = changesBySourcePath
        collectCustomSocketPasswordEdits(
            changesBySourcePath: &resolvedChangesBySourcePath,
            loadSocketPassword: loadSocketPassword
        )
        resolvedChangesBySourcePath = resolvedChangesBySourcePath.filter { !$0.value.isEmpty }
        guard !resolvedChangesBySourcePath.isEmpty else {
            return .noChanges
        }
        var didWriteChanges = false
        for sourcePath in resolvedChangesBySourcePath.keys.sorted() {
            let changesByPath = resolvedChangesBySourcePath[sourcePath] ?? [:]
            let changes = changesByPath.keys.sorted().map { jsonPath in
                (jsonPath: jsonPath, value: changesByPath[jsonPath]!)
            }
            guard await shouldContinue() else {
                return didWriteChanges ? .wroteChanges : .noChanges
            }
            try CmuxSettingsJSONWriter.write(changes, to: sourcePath, fileManager: fileManager)
            didWriteChanges = true
        }
        return .wroteChanges
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

    func write(
        _ plan: ManagedSettingsWriteBackPlan,
        shouldContinue: ManagedSettingsWriteBackShouldContinue
    ) async throws -> ManagedSettingsWriteBackOutcome {
        try await plan.write(fileManager: fileManager, shouldContinue: shouldContinue)
    }
}
