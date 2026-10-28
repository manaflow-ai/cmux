import CmuxNextDaemon

/// Each asked live terminal's foreground program (nil: its shell only, or no
/// answer in time). A terminal missing from it was not asked.
typealias RunningPrograms = [SurfaceID: String?]

extension Dictionary where Key == SurfaceID, Value == String? {
    /// The name of a command that runs (pushed state) before a read named its program.
    static var unnamed: String { "" }

    /// The programs, unique and sorted (named ones only).
    var programNames: [String] { Set(values.compactMap { $0 }.filter { !$0.isEmpty }).sorted() }

    /// Whether a command runs whose program is not named yet.
    var hasUnnamedProgram: Bool { values.contains { $0 == Self.unnamed } }

    /// Whether every terminal in `tabs` was asked, so its answer can stand in for asking again.
    func covers(_ tabs: [TabModel]) -> Bool { tabs.allSatisfy { keys.contains($0.surface) } }
}
