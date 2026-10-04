import Foundation

/// `updates.meteredNetwork`: what automatic downloads do on a metered link.
nonisolated public enum UpdateMeteredMode: String, Sendable, CaseIterable {
    /// Wait while Low Data Mode is on (default).
    case deferLowData = "defer-low-data"
    /// Also wait on expensive links (cellular, a phone hotspot).
    case deferExpensive = "defer-expensive"
    /// Always download.
    case download
}

/// Whether found updates download by themselves right now (pure). While
/// deferred, a found update waits as the available card and one click
/// downloads it.
nonisolated public enum UpdateNetworkPolicy {
    public static func downloadsAutomatically(setting: Bool, mode: UpdateMeteredMode, constrained: Bool, expensive: Bool) -> Bool {
        setting
    }
}
