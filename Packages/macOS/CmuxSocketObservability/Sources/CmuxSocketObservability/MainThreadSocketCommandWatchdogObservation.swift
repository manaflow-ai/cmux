import Foundation

/// A main-actor socket command that exceeded the watchdog deadline.
nonisolated public struct MainThreadSocketCommandWatchdogObservation: Sendable, Equatable {
    public let descriptor: SocketCommandDescriptor
    public let elapsedMs: Double
    public let thresholdMs: Double
    public let backtrace: [String]
}
