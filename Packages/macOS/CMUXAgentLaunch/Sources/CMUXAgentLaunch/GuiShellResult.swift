/// Captured output and the authoritative directory after a GUI shell command.
public struct GuiShellResult: Sendable, Equatable, Codable {
    /// Last bounded portion of combined stdout and stderr.
    public let output: String
    /// Shell exit status of the submitted command.
    public let exitCode: Int32
    /// Directory reported by the shell after execution, including failed commands.
    public let workingDirectory: String
}
