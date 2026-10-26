import Foundation

/// The targets ``DaemonUpdatePolicy`` already tried for one bundled build, kept across launches in
/// `attempted.json`, so a relaunch never retries a target that rolled back or failed on this
/// build (``attempted(_:)``). A new build starts an empty ledger.
nonisolated struct DaemonUpdateLedger: Codable, Sendable, Equatable {
    /// The bundled build hash the entries belong to.
    var build: String
    /// Target id to its final outcome (`updated`, `rolledBack`, ...).
    var targets: [String: String]

    init(build: String, targets: [String: String] = [:]) {
        self.build = build
        self.targets = targets
    }

    static func file(in directory: URL) -> URL { directory.appendingPathComponent("attempted.json") }

    /// The id that stands for every target: an unreadable ledger blocks its whole build.
    static let everyTarget = "*"

    /// Whether `id` already has a final outcome on this build (or the ledger was unreadable).
    func attempted(_ id: String) -> Bool {
        targets[id] != nil || targets[Self.everyTarget] != nil
    }

    /// The ledger of `build` from `directory`; empty when the file is missing or of another build.
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
        return ledger.build == build ? ledger : DaemonUpdateLedger(build: build)
    }

    func write(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file(in: directory), options: .atomic)
    }
}
