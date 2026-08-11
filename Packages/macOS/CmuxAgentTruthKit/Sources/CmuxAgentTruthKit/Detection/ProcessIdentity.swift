import Foundation

/// Identifies a process by pid and optional start identity so pid reuse is safe when known.
public struct ProcessIdentity: Hashable, Sendable {
    /// The process identifier.
    public let pid: Int32
    /// The process start identity tick, when supplied by process observation.
    public let startTick: Int?

    /// Creates a process identity.
    /// - Parameters:
    ///   - pid: The process identifier.
    ///   - startTick: The process start identity tick, when known.
    public init(pid: Int32, startTick: Int?) {
        self.pid = pid
        self.startTick = startTick
    }
}
