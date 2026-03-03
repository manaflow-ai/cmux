import Foundation

/// Persistence store for scheduled task definitions.
/// Follows the same pattern as `SessionPersistenceStore`: enum namespace with static methods,
/// atomic JSON writes to App Support directory, bundle-ID-based filename isolation.
enum SchedulerPersistenceStore {

    static func load(fileURL: URL? = nil) -> [ScheduledTask] {
        guard let fileURL = fileURL ?? defaultSchedulerFileURL() else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let tasks = try? decoder.decode([ScheduledTask].self, from: data) else { return [] }
        return tasks
    }

    @discardableResult
    static func save(_ tasks: [ScheduledTask], fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSchedulerFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - File URL

    static func defaultSchedulerFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("scheduler-\(bundleId).json", isDirectory: false)
    }
}
