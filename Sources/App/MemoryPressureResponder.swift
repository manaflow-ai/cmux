import Foundation

@MainActor
protocol MemoryPressureResponder: AnyObject {
    var memoryPressureResponderID: String { get }
    var memoryPressureMinimumSeverity: MemoryPressureSeverity { get }
    var memoryPressurePriority: Int { get }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult
}
