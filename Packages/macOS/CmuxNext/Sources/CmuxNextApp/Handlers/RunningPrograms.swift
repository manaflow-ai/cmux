import CmuxNextDaemon

/// Each asked live terminal's foreground program (nil: its shell only, or no
/// answer in time). A terminal missing from it was not asked.
typealias RunningPrograms = [SurfaceID: String?]

extension Dictionary where Key == SurfaceID, Value == String? {
    /// The programs, unique and sorted.
    var programNames: [String] { Set(values.compactMap { $0 }).sorted() }

    /// Whether every terminal in `tabs` was asked, so its answer can stand in for asking again.
    func covers(_ tabs: [TabModel]) -> Bool { tabs.allSatisfy { keys.contains($0.surface) } }
}
