import Foundation

// Wire shapes of cmux-tui `loopback-forward-v1` (cmux-tui/spec/commands.md,
// "Loopback forwarding"; plans/cmux-next/remote-localhost.md section 4).

/// `loopback-open`: a TCP stream to the daemon machine's own loopback.
struct LoopbackOpenRequest: DaemonRequest {
    typealias Response = LoopbackOpenResponse
    static let command = "loopback-open"
    var stream: UInt64
    var host: String
    var port: UInt16
    /// This client's receive window (bytes the daemon may send before credit).
    var window: Int
}

struct LoopbackOpenResponse: Decodable, Sendable {
    var stream: UInt64
    var address: String
    /// The daemon's receive window.
    var window: Int
}

/// `loopback-status`: limits and the daemon's audit ring (diagnostics).
public struct LoopbackStatusRequest: DaemonRequest {
    public typealias Response = LoopbackStatus
    public static let command = "loopback-status"
    public init() {}
}
