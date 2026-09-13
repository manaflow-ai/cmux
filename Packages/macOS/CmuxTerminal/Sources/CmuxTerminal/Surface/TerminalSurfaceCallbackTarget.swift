/// Sendable bridge for C renderer callbacks that must hop back to the main
/// actor without retaining the surface model through its callback context.
@MainActor
final class TerminalSurfaceCallbackTarget {
    weak var surface: TerminalSurface?

    init(surface: TerminalSurface) {
        self.surface = surface
    }
}
