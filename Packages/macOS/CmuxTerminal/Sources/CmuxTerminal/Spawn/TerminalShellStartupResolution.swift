extension TerminalShellStartupPolicy {
    /// The result of resolving declarative shell-startup ownership.
    public struct Resolution: Equatable, Sendable {
        /// Whether the declarative shell mode and startup command may apply.
        public let allowsDeclarativeShellStartup: Bool

        /// Effective mode, falling back to login when another startup owner
        /// already controls the surface.
        public let mode: TerminalShellStartupMode

        /// Creates a resolved startup decision.
        public init(
            allowsDeclarativeShellStartup: Bool,
            mode: TerminalShellStartupMode
        ) {
            self.allowsDeclarativeShellStartup = allowsDeclarativeShellStartup
            self.mode = mode
        }
    }
}
