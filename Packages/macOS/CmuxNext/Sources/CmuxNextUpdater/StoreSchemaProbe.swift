public import Foundation
import CmuxNextWakeups

/// The daemon store schemas a cmux bundle's own CLI reports
/// (`cmux __store-schemas`, cmux-tui `store_schemas.rs`): the newest schema
/// of each store that build reads, or the newest each store holds on disk.
/// Rollback compares the two (``RollbackDecision``). Each call runs a
/// process off the caller's actor and awaits it without holding a thread
/// (AsyncProcess).
nonisolated public struct StoreSchemaProbe: Sendable {
    /// The bundle whose CLI answers.
    public let bundle: URL
    public var timeout: Duration

    public init(bundle: URL, timeout: Duration = .seconds(10)) {
        self.bundle = bundle
        self.timeout = timeout
    }

    /// What the build reads; nil when its CLI cannot say (it predates the
    /// probe, or fails).
    public func readable() async -> [String: Int]? {
        await run(arguments: [], environment: [:])
    }

    /// The newest schema each store holds under any of `stateDirectories`
    /// (nil: cmux-tui's default state root), as the build's CLI reads it;
    /// nil when any of them cannot be read.
    public func stored(stateDirectories: [URL?]) async -> [String: Int]? {
        var newest: [String: Int] = [:]
        for directory in stateDirectories {
            var environment: [String: String] = [:]
            if let directory { environment["CMUX_TUI_STATE_DIR"] = directory.path }
            guard let found = await run(arguments: ["--stored"], environment: environment) else { return nil }
            newest.merge(found, uniquingKeysWith: max)
        }
        return newest
    }

    var cli: URL { bundle.appending(path: "Contents/Resources/bin/cmux") }

    /// Runs `cli __store-schemas arguments` with `environment` over this
    /// process's; nil on a launch failure, a non-zero exit, a timeout or
    /// output that is not one JSON object of integers. `@concurrent`: the
    /// caller (rollback inputs) is main-actor, and the environment copy, the
    /// spawn and the parse stay off the main thread.
    @concurrent func run(arguments: [String], environment: [String: String]) async -> [String: Int]? {
        let request = ProcessRequest(cli, ["__store-schemas"] + arguments,
                                     environment: ProcessInfo.processInfo.environment.merging(environment) { $1 },
                                     timeout: timeout)
        guard let outcome = try? await AsyncProcess().run(request), outcome.succeeded else { return nil }
        return Self.parse(outcome.output)
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
