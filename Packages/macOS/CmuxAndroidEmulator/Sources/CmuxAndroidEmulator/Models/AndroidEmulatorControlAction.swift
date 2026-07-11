/// A user interaction routed to one validated Android emulator transport.
public enum AndroidEmulatorControlAction: Sendable, Equatable {
    /// Presses the virtual power button.
    case power
    /// Raises media volume.
    case volumeUp
    /// Lowers media volume.
    case volumeDown
    /// Rotates the display counterclockwise.
    case rotateLeft
    /// Rotates the display clockwise.
    case rotateRight
    /// Presses Android Back.
    case back
    /// Presses Android Home.
    case home
    /// Opens Android Overview.
    case overview
    /// Taps a display coordinate.
    case tap(x: Int, y: Int)
    /// Swipes between display coordinates over the supplied duration.
    case swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMilliseconds: Int)
}
