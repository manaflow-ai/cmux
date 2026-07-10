/// A user interaction routed to one validated Android emulator transport.
public enum AndroidEmulatorControlAction: Sendable, Equatable {
    case power
    case volumeUp
    case volumeDown
    case rotateLeft
    case rotateRight
    case back
    case home
    case overview
    case tap(x: Int, y: Int)
    case swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMilliseconds: Int)
}
