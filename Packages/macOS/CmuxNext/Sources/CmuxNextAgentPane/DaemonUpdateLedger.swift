import Foundation

/// The targets ``DaemonUpdatePolicy`` already tried for one bundled build, kept across launches in
/// `attempted.json`, so a relaunch never retries a target that rolled back or failed on this
/// build. A new build starts an empty ledger.
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

    /// The ledger of `build` from `directory`; empty when the file is missing, unreadable or of
    /// another build.
    static func read(_ directory: URL, build: String) -> DaemonUpdateLedger {
        guard let data = try? Data(contentsOf: file(in: directory)),
              let ledger = try? JSONDecoder().decode(Self.self, from: data), ledger.build == build else {
            return DaemonUpdateLedger(build: build)
        }
        return ledger
    }

    func write(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file(in: directory), options: .atomic)
    }
}
