import Foundation

extension ReconnectOwner {
    /// Bounds the retry delay owned by a single reconnect loop.
    public struct Config: Sendable {
        /// Delay before the first retry after a failed attempt.
        public var initialBackoff: Duration
        /// Upper bound for exponential retry delays.
        public var maxBackoff: Duration

        /// Creates retry bounds for responsive recovery without a retry storm.
        ///
        /// - Parameters:
        ///   - initialBackoff: First retry delay; defaults to 400 milliseconds.
        ///   - maxBackoff: Delay cap; defaults to 30 seconds.
        public init(
            initialBackoff: Duration = .milliseconds(400),
            maxBackoff: Duration = .seconds(30)
        ) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
        }
    }

}
