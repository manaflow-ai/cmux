import Foundation

extension Duration {
    /// The duration in seconds as a `TimeInterval`.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
