/// A ``CmuxCommandDefinition`` paired with the `cmux.json` source path it was
/// resolved from, used when reporting and executing config commands.
public struct CmuxResolvedCommand: Sendable {
    /// The resolved command definition.
    public let command: CmuxCommandDefinition
    /// The `cmux.json` path the command was declared in, or `nil` when unknown.
    public let sourcePath: String?

    /// Creates a resolved command.
    public init(command: CmuxCommandDefinition, sourcePath: String?) {
        self.command = command
        self.sourcePath = sourcePath
    }
}
