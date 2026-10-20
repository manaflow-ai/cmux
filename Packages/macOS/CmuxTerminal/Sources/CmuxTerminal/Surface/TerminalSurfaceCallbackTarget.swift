/// Sendable bridge for C renderer callbacks that must hop back to the main
/// actor without retaining the surface model through its callback context.
final class TerminalSurfaceCallbackTarget: @unchecked Sendable {
    weak var surface: TerminalSurface?

    init(surface: TerminalSurface) {
        self.surface = surface
    }
}
