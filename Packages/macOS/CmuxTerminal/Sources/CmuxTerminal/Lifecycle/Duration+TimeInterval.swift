import Foundation

extension Duration {
    /// Converts a positive `Duration` into the seconds value expected by `Timer`.
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
