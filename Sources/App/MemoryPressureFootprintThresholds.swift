import Foundation

struct MemoryPressureFootprintThresholds: Equatable, Sendable {
    static let `default` = MemoryPressureFootprintThresholds(
        warningBytes: 8 * 1024 * 1024 * 1024,
        criticalBytes: 16 * 1024 * 1024 * 1024
    )

    let warningBytes: UInt64
    let criticalBytes: UInt64

    init(warningBytes: UInt64, criticalBytes: UInt64) {
        self.warningBytes = warningBytes
        self.criticalBytes = max(criticalBytes, warningBytes)
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
}
