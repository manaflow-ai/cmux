import CoreGraphics

/// When a drag with the keyboard up holds the prompt on the composer
/// (design/terminal M6, R3-1). Only once the touch has reached the keyboard,
/// so the keyboard follows the finger, and only for a drag that began at the
/// prompt: the part of the gesture that moves the keyboard ends with the
/// prompt on the composer. Above the keyboard a pull-down scrolls the history
/// like any scroll view (as in Messages).
public struct KeyboardDragPin: Equatable, Sendable {
    /// The drag began while following the prompt with the soft keyboard up.
    public private(set) var candidate = false
    /// The keyboard follows the finger: the content stays on the composer.
    public private(set) var pinning = false

    public init() {}

    public mutating func began(following: Bool, keyboardUp: Bool, isTUI: Bool) {
        candidate = following && keyboardUp && !isTUI
        pinning = false
    }

    /// The finger moved: `fingerY` and `keyboardTop` in the page's points.
    public mutating func moved(fingerY: CGFloat, keyboardTop: CGFloat) {
        guard candidate, !pinning else { return }
        if fingerY >= keyboardTop - 2 { pinning = true }
    }

    public mutating func ended() {
        candidate = false
        pinning = false
    }
}
