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
    /// nil when any of them cannot be read. Each ask gives the check an end
    /// time (``checkEndMilliseconds``), and a check that ends before it read
    /// each session says how many sessions it read. The rule for one
    /// directory is at ``stored(environment:calls:)``. All the directories
    /// together get ``maxStoredCalls`` calls of the CLI at most, and one call
    /// stays for each directory after the one in work: no directory loses
    /// its place for a call to a directory before it.
    public func stored(stateDirectories: [URL?]) async -> [String: Int]? {
        var newest: [String: Int] = [:]
        var callsLeft = Self.maxStoredCalls
        for (index, directory) in stateDirectories.enumerated() {
            var environment: [String: String] = [:]
            if let directory { environment["CMUX_TUI_STATE_DIR"] = directory.path }
            let limit = max(1, callsLeft - (stateDirectories.count - index - 1))
            let (found, calls) = await stored(environment: environment, calls: limit)
            callsLeft -= calls
            guard let found else { return nil }
            newest.merge(found, uniquingKeysWith: max)
        }
        return newest
    }

    /// The end time each call of ``stored(stateDirectories:)`` gives the
    /// check, in milliseconds. It is below the default ``timeout``: the check
    /// of an ask ends by itself before the first session that it would read
    /// after its end time, and the timeout stops an ask that goes on above
    /// it. A call with no end time has only the timeout as its bound.
    static let checkEndMilliseconds = 5000
    /// The most calls of the CLI in one ``stored(stateDirectories:)``; with
    /// more directories than that, one call for each.
    static let maxStoredCalls = 6

    /// One state root's stored schemas, and how many calls of the CLI that
    /// took, `limit` at most (1 or more).
    ///
    /// Each ask has the end time. A `not_ready` answer whose count of
    /// sessions read is above the count of the ask before it (at the first
    /// ask: above 0) is asked again. The last call that the root can use is
    /// a call with no end time, as before the end time was there, and that
    /// call's answer is the answer: a check that one call with the whole
    /// ``timeout`` can end must not lose its answer to the end time. So a
    /// root makes `limit - 1` asks at most. A `not_ready` answer with the
    /// same count, a smaller one or none goes to that call at once. So does
    /// a CLI that ends an ask by itself with a non-zero exit: the CLI of a
    /// build from before the end time refuses it, and a failure that comes
    /// and goes must not end the root. One state root gets one call with no
    /// end time at most. The schemas are nil when that call gives none, and
    /// when an ask did not start, the timeout or a signal ended it, or it
    /// ended with exit 0 and an output of neither form.
    ///
    /// Each call of the check starts at the first session again, and the
    /// check keeps nothing of its own between 2 calls (cmux-tui
    /// `store_schemas.rs`). So a count grows only when the sessions that the
    /// call before read are faster to read now: by the file cache, and, for
    /// a check that writes a store at its first read of it, because that
    /// store is then written.
    func stored(environment: [String: String], calls limit: Int) async -> (schemas: [String: Int]?, calls: Int) {
        let inItsTime = ["--stored", "--within-ms", String(Self.checkEndMilliseconds)]
        var calls = 0
        var read = 0
        asks: while calls < limit - 1 {
            calls += 1
            switch await ask(arguments: inItsTime, environment: environment) {
            case .schemas(let schemas):
                return (schemas, calls)
            case .notReady(let now) where now > read:
                read = now
            case .notReady, .failed:
                break asks
            case .nothing:
                return (nil, calls)
            }
        }
        let plain = await run(arguments: ["--stored"], environment: environment)
        return (plain, calls + 1)
    }

    var cli: URL { bundle.appending(path: "Contents/Resources/bin/cmux") }

    /// What one call of the CLI gave.
    nonisolated enum Answer: Sendable {
        case schemas([String: Int])
        /// The check's end time came before it read each session: how many
        /// sessions it read, 0 when it does not say.
        case notReady(Int)
        /// The CLI ended by itself with a non-zero exit.
        case failed
        /// It did not start, the timeout ended it, or its output is neither form.
        case nothing
    }

    /// Runs `cli __store-schemas arguments` with `environment` over this
    /// process's; nil on a launch failure, a non-zero exit, a timeout or
    /// output that is not one JSON object of integers. `@concurrent`: the
    /// caller (rollback inputs) is main-actor, and the environment copy, the
    /// spawn and the parse stay off the main thread.
    @concurrent func run(arguments: [String], environment: [String: String]) async -> [String: Int]? {
        if case .schemas(let schemas) = await ask(arguments: arguments, environment: environment) { return schemas }
        return nil
    }

    /// ``run(arguments:environment:)`` with each way the call can end.
    @concurrent func ask(arguments: [String], environment: [String: String]) async -> Answer {
        let request = ProcessRequest(cli, ["__store-schemas"] + arguments,
                                     environment: ProcessInfo.processInfo.environment.merging(environment) { $1 },
                                     timeout: timeout)
        guard let outcome = try? await AsyncProcess().run(request) else { return .nothing }
        guard outcome.succeeded else { return outcome.exited ? .failed : .nothing }
        if let schemas = Self.parse(outcome.output) { return .schemas(schemas) }
        if let read = Self.notReadyCount(outcome.output) { return .notReady(read) }
        return .nothing
    }

    /// The count of sessions read in the check's `not_ready` answer
    /// (`{"not_ready":{"sessions":M,"sessions_read":R}}`): 0 when that answer
    /// has no count that is a number, nil for any other output.
    static func notReadyCount(_ data: Data) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let notReady = object["not_ready"] as? [String: Any] else { return nil }
        guard let read = notReady["sessions_read"] as? NSNumber,
              CFGetTypeID(read) != CFBooleanGetTypeID() else { return 0 }
        return read.intValue
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
