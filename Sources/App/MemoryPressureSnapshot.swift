import Foundation

struct MemoryPressureSnapshot: Equatable, Sendable {
    let severity: MemoryPressureSeverity
    let physicalFootprintBytes: UInt64?
    let sampledAt: Date
}
