/// Daemon-local handles allocated for one newly created terminal surface.
public struct BackendSurfacePlacement: Decodable, Equatable, Sendable {
    public let surface: UInt64
    public let pane: UInt64
    public let screen: UInt64
    public let workspace: UInt64
}
