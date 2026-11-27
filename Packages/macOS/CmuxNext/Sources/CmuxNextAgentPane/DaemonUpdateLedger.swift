import Foundation

/// The targets ``DaemonUpdatePolicy`` already tried for one bundled build, kept across launches in
/// `attempted.json`, so a relaunch never retries a target that rolled back or failed on this
/// build (``attempted(_:)``). A new build starts an empty ledger, except for ``cannotUpdate``.
nonisolated struct DaemonUpdateLedger: Codable, Sendable, Equatable {
    /// A target that answered it cannot take a build in place (``DaemonUpdateOutcome/unsupported(reason:)``).
    struct CannotUpdate: Codable, Sendable, Equatable {
        /// The build the target ran when it answered (never empty: an unknown build is not kept).
        var build: String
        /// What it said, the board's line.
        var reason: String
    }

    /// The bundled build hash the entries belong to.
    var build: String
    /// Target id to its final outcome (`updated`, `rolledBack`, ...).
    var targets: [String: String]
    /// Target id to its `unsupported` answer, kept across builds: a machine too old to update in
    /// place stays so for every later build of the app, until it runs another build itself. Nil in
    /// a ledger written before this field (optional, so such a ledger still reads).
    var cannotUpdate: [String: CannotUpdate]?

    init(build: String, targets: [String: String] = [:], cannotUpdate: [String: CannotUpdate]? = nil) {
        self.build = build
        self.targets = targets
        self.cannotUpdate = cannotUpdate
    }

    static func file(in directory: URL) -> URL { directory.appendingPathComponent("attempted.json") }

    /// The id that stands for every target: an unreadable ledger blocks its whole build.
    static let everyTarget = "*"

    /// Whether `id` already has a final outcome on this build (or the ledger was unreadable).
    func attempted(_ id: String) -> Bool {
        targets[id] != nil || targets[Self.everyTarget] != nil
    }

    /// The ledger of `build` from `directory`; empty when the file is missing or of another build,
    /// but for ``cannotUpdate``, which another build's ledger hands on.
    /// A file that is there but cannot be read or decoded may have held a rollback of this build:
    /// it becomes a ledger that blocks every target on `build` (written back, so the next build
    /// starts empty), never an empty one that would retry it.
    static func read(_ directory: URL, build: String) -> DaemonUpdateLedger {
        let url = file(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return DaemonUpdateLedger(build: build) }
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(Self.self, from: data) else {
            let blocked = DaemonUpdateLedger(build: build, targets: [everyTarget: "unreadable"])
            try? blocked.write(directory)
            return blocked
        }
        return ledger.build == build ? ledger : DaemonUpdateLedger(build: build, cannotUpdate: ledger.cannotUpdate)
    }

    func write(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file(in: directory), options: .atomic)
    }
}
