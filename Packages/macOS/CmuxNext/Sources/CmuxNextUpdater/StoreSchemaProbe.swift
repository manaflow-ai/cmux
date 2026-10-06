public import Foundation

/// The daemon store schemas a cmux bundle's own CLI reports
/// (`cmux __store-schemas`, cmux-tui `store_schemas.rs`): the newest schema
/// of each store that build reads, or the newest each store holds on disk.
/// Rollback compares the two (``RollbackDecision``). Each call runs a
/// process and waits for it, so callers stay off the main actor.
nonisolated public struct StoreSchemaProbe: Sendable {
    /// The bundle whose CLI answers.
    public let bundle: URL
    public var timeout: TimeInterval

    public init(bundle: URL, timeout: TimeInterval = 10) {
        self.bundle = bundle
        self.timeout = timeout
    }

    /// What the build reads; nil when its CLI cannot say (it predates the
    /// probe, or fails).
    public func readable() -> [String: Int]? {
        run(arguments: [], environment: [:])
    }

    /// The newest schema each store holds under any of `stateDirectories`
    /// (nil: cmux-tui's default state root), as the build's CLI reads it;
    /// nil when any of them cannot be read.
    public func stored(stateDirectories: [URL?]) -> [String: Int]? {
        var newest: [String: Int] = [:]
        for directory in stateDirectories {
            var environment: [String: String] = [:]
            if let directory { environment["CMUX_TUI_STATE_DIR"] = directory.path }
            guard let found = run(arguments: ["--stored"], environment: environment) else { return nil }
            newest.merge(found, uniquingKeysWith: max)
        }
        return newest
    }

    var cli: URL { bundle.appending(path: "Contents/Resources/bin/cmux") }

    /// Runs `cli __store-schemas arguments` with `environment` over this
    /// process's; nil on a launch failure, a non-zero exit, a timeout or
    /// output that is not one JSON object of integers.
    func run(arguments: [String], environment: [String: String]) -> [String: Int]? {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["__store-schemas"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // concurrency-allow: rollbackInputs runs the probe in a detached task; one bounded wait for the exit, no polling.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // concurrency-allow: off the main actor (detached task); bounded by `timeout`.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // concurrency-allow: the process has exited, so the read ends at its few bytes of JSON.
        return Self.parse(output.fileHandleForReading.readDataToEndOfFile())
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
