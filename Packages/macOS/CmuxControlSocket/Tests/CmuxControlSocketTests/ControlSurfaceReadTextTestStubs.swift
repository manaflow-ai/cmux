@testable import CmuxControlSocket

extension ControlSurfaceContext {
    func controlSurfaceReadTextStrings() -> ControlSurfaceReadTextStrings {
        ControlSurfaceReadTextStrings(linesMustBeGreaterThanZero: "lines must be greater than 0")
    }
}
