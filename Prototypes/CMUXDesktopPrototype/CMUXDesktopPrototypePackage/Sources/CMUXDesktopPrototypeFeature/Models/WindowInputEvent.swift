import AppKit
import CoreGraphics

enum WindowMouseButton {
    case left
    case right
    case other(Int)
}

enum WindowMousePhase {
    case down
    case dragged
    case up
    case moved
}

struct WindowMouseInput {
    var phase: WindowMousePhase
    var button: WindowMouseButton
    var normalizedPoint: CGPoint
    var clickCount: Int
}

struct WindowScrollInput {
    var normalizedPoint: CGPoint
    var deltaX: Double
    var deltaY: Double
}

struct WindowKeyInput {
    var keyCode: UInt16
    var characters: String?
    var modifierFlags: NSEvent.ModifierFlags
    var isDown: Bool
    var isRepeat: Bool
}

enum WindowInputResult: Equatable {
    case succeeded
    case accessibilityPermissionMissing
    case eventCreationFailed
}
