import CoreGraphics

struct SimulatorPendingPointerEntry {
    var previousLocation: CGPoint
    let optionPinch: Bool
    let parallelPan: Bool
    let source: SimulatorPointerEntrySource
}
