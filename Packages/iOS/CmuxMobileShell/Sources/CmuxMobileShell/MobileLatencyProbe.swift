#if DEBUG
import Foundation

/// Process-scoped configuration and claim gate for the DEBUG typing probe.
@MainActor
enum MobileLatencyProbe {
    struct Configuration {
        let count: Int
        let intervalMilliseconds: Int
    }

    private static let configuration: Configuration? = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_LATENCY_PROBE"] else {
            return nil
        }
        if raw == "1" {
            return Configuration(count: 40, intervalMilliseconds: 250)
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let count = Int(parts[0]), count > 0,
              let intervalMilliseconds = Int(parts[1]), intervalMilliseconds > 0 else {
            return nil
        }
        return Configuration(count: count, intervalMilliseconds: intervalMilliseconds)
    }()

    private static var hasClaimedProcessRun = false
    private static var hasAutoNavigatedProcessRun = false

    static var hasUnclaimedConfiguration: Bool {
        configuration != nil && !hasClaimedProcessRun
    }

    static func claimAutoNavigation() -> Bool {
        guard hasUnclaimedConfiguration, !hasAutoNavigatedProcessRun else {
            return false
        }
        hasAutoNavigatedProcessRun = true
        return true
    }

    static func claimConfiguration() -> Configuration? {
        guard !hasClaimedProcessRun, let configuration else { return nil }
        hasClaimedProcessRun = true
        return configuration
    }

    static func input(at index: Int) -> Data {
        Data([UInt8(ascii: "a") + UInt8(index % 26)])
    }
}
#endif
