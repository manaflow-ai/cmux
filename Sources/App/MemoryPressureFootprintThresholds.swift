import Foundation

struct MemoryPressureFootprintThresholds: Equatable, Sendable {
    static let `default` = MemoryPressureFootprintThresholds.scaled(
        forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )

    let warningBytes: UInt64
    let criticalBytes: UInt64

    init(warningBytes: UInt64, criticalBytes: UInt64) {
        self.warningBytes = warningBytes
        self.criticalBytes = max(criticalBytes, warningBytes)
    }

    /// Scales footprint pressure thresholds to installed RAM.
    ///
    /// Issue #7596 found that fixed 8/16 GiB thresholds never fired because a
    /// bloated real session plateaued around 2 GiB. RAM-scaled thresholds engage
    /// the renderer, browser, and notification responders on machines where
    /// cmux's footprint is significant: 8/16 GiB RAM -> 2/4 GiB, 36 GiB ->
    /// 3/6 GiB, 64 GiB -> about 5.3/10.7 GiB, and 128+ GiB caps at 6/12 GiB.
    static func scaled(
        forPhysicalMemoryBytes physicalMemoryBytes: UInt64
    ) -> MemoryPressureFootprintThresholds {
        MemoryPressureFootprintThresholds(
            warningBytes: clamped(
                physicalMemoryBytes / 12,
                lowerBound: gib(2),
                upperBound: gib(6)
            ),
            criticalBytes: clamped(
                physicalMemoryBytes / 6,
                lowerBound: gib(4),
                upperBound: gib(12)
            )
        )
    }

    func severity(forPhysicalFootprintBytes bytes: UInt64?) -> MemoryPressureSeverity {
        guard let bytes else { return .normal }
        if bytes >= criticalBytes {
            return .critical
        }
        if bytes >= warningBytes {
            return .warning
        }
        return .normal
    }

    private static func gib(_ value: UInt64) -> UInt64 {
        value * 1024 * 1024 * 1024
    }

    private static func clamped(
        _ value: UInt64,
        lowerBound: UInt64,
        upperBound: UInt64
    ) -> UInt64 {
        min(max(value, lowerBound), upperBound)
    }
}
