/// Post-start input produced for a restored surface resume binding.
public struct WorkspaceSurfaceResumeStartupLaunch: Equatable, Sendable {
    /// Input sent to the terminal's normally initialized shell.
    public let initialInput: String

    /// Creates a post-start input launch.
    public static func input(_ input: String) -> Self {
        Self(initialInput: input)
    }
}
