import CoreGraphics

struct SimulatorPendingPointerEntry {
    enum Source {
        case surface
        case stageHalo
    }

    var previousLocation: CGPoint
    let optionPinch: Bool
    let parallelPan: Bool
    let source: Source
}
