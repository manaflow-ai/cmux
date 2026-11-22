import Foundation

/// The connection to the Mac dropped or went quiet for a moment (a reconnect, a stalled channel),
/// as opposed to the Mac refusing something. A screen that shows content keeps showing it, says
/// it is reconnecting, and asks again on its own; it shows ``message`` only after
/// ``ConnectionPatience/giveUpAfter`` without an answer.
public struct ConnectionInterrupted: Error, Equatable, Sendable, LocalizedError {
    /// What a failure state says once the connection stayed down past the bound: what happened
    /// and what to do, never a raw timeout.
    public static let message = "Can't reach your Mac right now. Make sure it's awake and cmux is open. This page reconnects on its own."

    public init() {}

    public var errorDescription: String? { Self.message }
}

/// How long a screen rides out an interrupted connection before it says so, and how often it
/// asks again meanwhile.
public enum ConnectionPatience {
    /// A reconnect after the app was in the background, or a channel replaced after a stall,
    /// is back well within this.
    public static let giveUpAfter: Duration = .seconds(45)
    /// A blip the person can do nothing about shows nothing until it has lasted this long
    /// (handbook connection-state-with-no-action-or-bound: the shared notice bound, 10 s).
    public static let quietFor: Duration = .seconds(10)
    /// The waits between quiet retries: quick first, then steady.
    public static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]

    public static func delay(attempt: Int) -> Duration {
        retryDelays[min(max(attempt, 0), retryDelays.count - 1)]
    }
}
