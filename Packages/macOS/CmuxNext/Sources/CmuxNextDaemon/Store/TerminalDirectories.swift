/// The folder each local terminal's shell last reported to this app (OSC 7),
/// by surface: it outlives tab rebuilds, which re-seed `TabModel.cwd` from it,
/// and is dropped when the daemon generation changes, since surface ids name
/// terminals of one generation.
@MainActor
struct TerminalDirectories {
    private var bySurface: [SurfaceID: String] = [:]
    private var generation: DaemonGeneration?

    subscript(surface: SurfaceID) -> String? { bySurface[surface] }

    /// Stores the reported folder's path (`TabModel.path(reported:)`; nil for
    /// none or a report that names no local folder) and returns it.
    mutating func note(_ reported: String?, surface: SurfaceID) -> String? {
        bySurface[surface] = reported.flatMap(TabModel.path(reported:))
        return bySurface[surface]
    }

    mutating func follow(_ value: DaemonGeneration?) {
        guard let value, generation != value else { return }
        if generation != nil { bySurface = [:] }
        generation = value
    }
}
