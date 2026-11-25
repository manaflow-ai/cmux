public import Foundation

/// Reads where a Chief runs from its home's `state/moved.json` (``ChiefLocation``), with a running
/// move and its fork (``ChiefHomeMarks``), off the main thread.
///
/// Tests pass a temporary folder as the home:
///
/// ```swift
/// let location = await ChiefLocationReader().read(home: temporaryHome)
/// ```
public nonisolated struct ChiefLocationReader: Sendable {
    /// The engine's marker, relative to a Chief home (optchat-chief migrate.rs `MOVED_FILE`).
    public static let movedFile = "state/moved.json"
    /// A running move's hold (migrate.rs `MOVING_FILE`).
    public static let movingFile = "state/moving.json"
    /// The home's fork in cmux Cloud (migrate_fork.rs `FORK_FILE`).
    public static let forkFile = "state/fork.json"
    /// Whether a pid runs (tests pass a fake; the default asks the kernel with signal 0).
    private let isRunning: @Sendable (Int32) -> Bool

    /// - Parameter isRunning: Whether a pid runs (a hold whose mover is gone does not count).
    public init(isRunning: @escaping @Sendable (Int32) -> Bool = ChiefLocationReader.processRuns) {
        self.isRunning = isRunning
    }

    /// Whether `pid` runs: signal 0 reaches it, or it runs as another user (EPERM).
    @Sendable public static func processRuns(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The location `home`'s marker names; This Mac when there is none.
    ///
    /// - Parameter home: A Chief home (`ChiefHome.root`).
    /// - Returns: Where that Chief runs now.
    public func read(home: URL) async -> ChiefLocation {
        await whereabouts(home: home).location
    }

    /// Where `home`'s marker says the Chief went, with the hosted Chief's agent id for cmux Cloud.
    ///
    /// - Parameter home: A Chief home (`ChiefHome.root`).
    public func whereabouts(home: URL) async -> ChiefWhereabouts {
        await marks(home: home).whereabouts
    }

    /// Everything `home`'s `state` folder says about moves (``ChiefHomeMarks``).
    ///
    /// - Parameter home: A Chief home (`ChiefHome.root`).
    public func marks(home: URL) async -> ChiefHomeMarks {
        let files = [Self.movedFile, Self.movingFile, Self.forkFile].map { home.appendingPathComponent($0) }
        let isRunning = isRunning
        // Three small file reads, at the person's priority, never on the main actor.
        return await Task.detached(priority: .userInitiated) {
            let data = files.map { try? Data(blockingContentsOf: $0) }
            return ChiefHomeMarks(movedJSON: data[0], movingJSON: data[1], forkJSON: data[2], isRunning: isRunning)
        }.value
    }
}
