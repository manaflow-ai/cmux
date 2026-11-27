import Foundation

/// macOS energy mode (the System Settings → Battery "Energy Mode" picker).
enum SleepyEnergyMode: Int, Sendable {
    /// Automatic energy management.
    case automatic = 0
    /// Low Power Mode.
    case low = 1
    /// High Power Mode.
    case high = 2
}
