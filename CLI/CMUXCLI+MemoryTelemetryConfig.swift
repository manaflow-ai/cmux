import Foundation

extension CMUXCLI {
    func memoryTelemetryDatabaseURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CMUX_MEMORY_TELEMETRY_DB_PATH"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.memory.error.databasePathEmpty",
                    defaultValue: "memory telemetry database path must not be empty"
                ))
            }

            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.memory.error.databasePathIsDirectory",
                        defaultValue: "memory telemetry database path must point to a file, not a directory: %@"
                    ),
                    url.path
                ))
            }
            return url
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("telemetry.db", isDirectory: false)
    }

    func memoryTelemetryRetention() throws -> TimeInterval {
        guard let rawValue = ProcessInfo.processInfo.environment["CMUX_MEMORY_TELEMETRY_RETENTION_SECONDS"] else {
            return 24 * 60 * 60
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else {
            throw CLIError(message: String(
                localized: "cli.memory.error.retentionInvalid",
                defaultValue: "memory telemetry retention must be a positive number of seconds"
            ))
        }
        return value
    }
}
