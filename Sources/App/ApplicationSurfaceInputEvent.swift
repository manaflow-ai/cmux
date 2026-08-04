import Foundation

struct ApplicationSurfaceInputEvent: Equatable, Sendable {
    let kind: ApplicationSurfaceInputEventKind
    var frameSequence: UInt64 = 0
    var x: Double = 0
    var y: Double = 0
    var keyCode: UInt16 = 0
    var keyDown: Bool = false
    var modifiers: UInt64 = 0
    var clickCount: Int = 1
    var deltaX: Double = 0
    var deltaY: Double = 0
}
