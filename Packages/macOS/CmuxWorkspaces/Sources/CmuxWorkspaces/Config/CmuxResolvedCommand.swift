/// A ``CmuxCommandDefinition`` paired with the config file path it was loaded
/// from, so downstream resolution can attribute the command to its source for
/// trust and icon-path purposes.
public struct CmuxResolvedCommand: Sendable {
    public let command: CmuxCommandDefinition
    public let sourcePath: String?

    public init(command: CmuxCommandDefinition, sourcePath: String?) {
        self.command = command
        self.sourcePath = sourcePath
    }
}
