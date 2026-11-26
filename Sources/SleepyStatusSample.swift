import Foundation

/// A sampled battery + Wi-Fi reading for the Sleepy Mode status pixels.
struct SleepyStatusSample: Sendable {
    /// Battery charge 0...1, or nil on a desktop with no battery.
    var batteryLevel: Double?
    /// Whether the battery is charging.
    var charging: Bool
    /// Wi-Fi signal bars 0...4, or nil if unknown/unavailable.
    var wifiBars: Int?
}
