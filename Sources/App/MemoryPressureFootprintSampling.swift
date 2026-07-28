import Foundation

protocol MemoryPressureFootprintSampling: Sendable {
    func physicalFootprintBytes() -> UInt64?
}
