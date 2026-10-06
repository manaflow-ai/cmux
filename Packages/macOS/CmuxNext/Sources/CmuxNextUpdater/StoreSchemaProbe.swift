public import Foundation

/// The daemon store schemas a cmux bundle's own CLI reports
/// (`cmux __store-schemas`, cmux-tui `store_schemas.rs`): the newest schema
/// of each store that build reads, or the newest each store holds on disk.
/// Rollback compares the two (``RollbackDecision``).
nonisolated public enum StoreSchemaProbe {
    /// What the build at `bundle` reads; nil when its CLI cannot say (it
    /// predates the probe, or fails).
    public static func readable(bundle: URL) -> [String: Int]? {
        run(cli(of: bundle), arguments: [], environment: [:])
    }

    /// The newest schema each store holds under any of `stateDirectories`
    /// (nil: cmux-tui's default state root), as the CLI of `bundle` reads
    /// it; nil when any of them cannot be read.
    public static func stored(bundle: URL, stateDirectories: [URL?]) -> [String: Int]? {
        var newest: [String: Int] = [:]
        for directory in stateDirectories {
            var environment: [String: String] = [:]
            if let directory { environment["CMUX_TUI_STATE_DIR"] = directory.path }
            guard let found = run(cli(of: bundle), arguments: ["--stored"], environment: environment) else { return nil }
            newest.merge(found, uniquingKeysWith: max)
        }
        return newest
    }

    static func cli(of bundle: URL) -> URL {
        bundle.appending(path: "Contents/Resources/bin/cmux")
    }

    /// Runs `cli __store-schemas arguments` with `environment` over this
    /// process's; nil on a launch failure, a non-zero exit, a timeout or
    /// output that is not one JSON object of integers.
    static func run(_ cli: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 10) -> [String: Int]? {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["__store-schemas"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return parse(output.fileHandleForReading.readDataToEndOfFile())
    }

    static func parse(_ data: Data) -> [String: Int]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var schemas: [String: Int] = [:]
        for (store, value) in object {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            schemas[store] = number.intValue
        }
        return schemas
    }
}
