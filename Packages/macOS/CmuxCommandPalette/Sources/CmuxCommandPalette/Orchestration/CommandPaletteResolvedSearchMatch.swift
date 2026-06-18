import Foundation

/// One resolved match produced by ``CommandPaletteSearchOrchestrator``,
/// merged across the nucleo and Swift engines.
public struct CommandPaletteResolvedSearchMatch: Sendable {
    /// The matched command's identifier.
    public let commandID: String
    /// Final merged score.
    public let score: Int
    /// Title character indices to highlight.
    public let titleMatchIndices: Set<Int>

    /// Creates a resolved match.
    public init(commandID: String, score: Int, titleMatchIndices: Set<Int>) {
        self.commandID = commandID
        self.score = score
        self.titleMatchIndices = titleMatchIndices
    }
}
