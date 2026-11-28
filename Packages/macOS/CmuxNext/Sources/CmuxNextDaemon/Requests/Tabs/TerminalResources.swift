import Foundation

/// `terminal-resources {surfaces?}` (capability `terminal-resources-v1`):
/// each terminal's process tree (the shell first, then every descendant)
/// and its terminal host, with cumulative CPU time and memory, read by the
/// daemon when asked. Nothing is sampled in the background, so a CPU
/// percentage needs two calls (the resource hover cards make one per
/// second while a card is open).
public struct TerminalResourcesRequest: DaemonRequest {
    public static let command = "terminal-resources"
    public static let requiredCapability: String? = capability
    public static let capability = "terminal-resources-v1"

    /// Nil asks for every PTY surface.
    public private(set) var surfaces: [SurfaceID]?

    /// A stand-in tab's surface (a Ctrl-` or split still opening) is left out: its terminal has no process in the daemon
    /// yet, and a request that names a stand-in is refused before it is sent (rule b), which showed the person "This pane
    /// is still opening" for a resource read they never asked for. A list of only stand-ins asks for no terminal.
    public init(surfaces: [SurfaceID]?) {
        // The boundary's own test (`DaemonRequestExecutor.standInReference`), so the two never disagree.
        self.surfaces = surfaces?.filter { $0.rawValue < ProvisionalPane.firstHandle }
    }

    public typealias Process = TerminalResourceProcess
    public typealias Terminal = TerminalResources
    public typealias Response = TerminalResourcesResult
}
