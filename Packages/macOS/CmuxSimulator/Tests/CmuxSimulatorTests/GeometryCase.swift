import Testing
@testable import CmuxSimulator

struct GeometryCase: Sendable, CustomTestStringConvertible {
    let name: String
    let rawWidth: Int
    let rawHeight: Int
    let orientation: SimulatorOrientation
    let needsTransform: Bool
    let rotationDegrees: Int
    let displayWidth: Int
    let displayHeight: Int
    let primary: SimulatorPoint
    let secondary: SimulatorPoint
    let delta: SimulatorInputDelta
    let edge: SimulatorEdge

    var testDescription: String { name }
}
