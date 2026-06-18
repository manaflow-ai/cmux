/// Launch action produced for a restored surface resume binding.
public enum WorkspaceSurfaceResumeStartupLaunch: Equatable, Sendable {
    /// Start the restored terminal with a command.
    case command(String)
    /// Send input to the restored terminal after it starts.
    case input(String)

    /// The command payload when this launch uses command startup.
    public var initialCommand: String? {
        if case .command(let command) = self {
            return command
        }
        return nil
    }

    /// The input payload when this launch uses post-start input.
    public var initialInput: String? {
        if case .input(let input) = self {
            return input
        }
        return nil
    }
}
