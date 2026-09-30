import Foundation

/// Identifies which pressure signal is allowed to invoke a responder.
///
/// Aggregate pressure is intentionally a separate lane: aggregate accounting
/// may warn and offer idle-agent hibernation, but it must not implicitly invoke
/// responders that release unrelated resources.
enum MemoryPressureResponderSignal: Sendable {
    case system
    case aggregate
}

/// Declares the pressure lanes a responder participates in.
enum MemoryPressureResponderScope: Sendable {
    case system
    case aggregate
    case all

    func accepts(_ signal: MemoryPressureResponderSignal) -> Bool {
        switch (self, signal) {
        case (.system, .system), (.aggregate, .aggregate), (.all, _):
            true
        default:
            false
        }
    }
}

@MainActor
protocol MemoryPressureResponder: AnyObject {
    var memoryPressureResponderID: String { get }
    var memoryPressureMinimumSeverity: MemoryPressureSeverity { get }
    var memoryPressurePriority: Int { get }
    var memoryPressureResponderScope: MemoryPressureResponderScope { get }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult
}

extension MemoryPressureResponder {
    /// Existing responders remain on the ordinary system-pressure lane unless
    /// they explicitly opt into aggregate pressure.
    var memoryPressureResponderScope: MemoryPressureResponderScope { .system }
}
