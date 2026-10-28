/// A network condition for a Chromium page (`Network.emulateNetworkConditions`),
/// with the values of Chromium DevTools' own presets.
public nonisolated enum WebDevToolsThrottle: String, CaseIterable, Hashable, Sendable {
    /// No throttling.
    case none
    /// No network.
    case offline
    /// DevTools' "3G" (formerly "Slow 3G"): 2 s latency, 50 kB/s each way.
    case slow3G
    /// DevTools' "Slow 4G" (formerly "Fast 3G"): 562.5 ms latency, 180 kB/s down, 84.4 kB/s up.
    case fast3G

    /// The `Network.emulateNetworkConditions` parameters. A throughput of
    /// -1 turns throttling off.
    public var parameters: [String: any Sendable] {
        switch self {
        case .none:
            ["offline": false, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1]
        case .offline:
            ["offline": true, "latency": 0, "downloadThroughput": 0, "uploadThroughput": 0]
        case .slow3G:
            ["offline": false, "latency": 2000, "downloadThroughput": 50_000, "uploadThroughput": 50_000]
        case .fast3G:
            ["offline": false, "latency": 562.5, "downloadThroughput": 180_000, "uploadThroughput": 84_375]
        }
    }
}
