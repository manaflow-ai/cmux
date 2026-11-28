import Foundation

/// One scored, displayable palette row: the command plus its score and the
/// title characters to highlight.
public struct CommandPaletteSearchResult: Identifiable {
    /// The matched command.
    public let command: CommandPaletteCommand
    /// Final score including boosts.
    public let score: Int
    /// Title character indices to highlight.
    public let titleMatchIndices: Set<Int>

    /// Creates a search result row.
    public init(command: CommandPaletteCommand, score: Int, titleMatchIndices: Set<Int>) {
        self.command = command
        self.score = score
        self.titleMatchIndices = titleMatchIndices
    }

    /// The command's identifier.
    public var id: String { command.id }
}
