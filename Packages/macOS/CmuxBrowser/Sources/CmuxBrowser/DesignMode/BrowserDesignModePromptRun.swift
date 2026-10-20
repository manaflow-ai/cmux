import Foundation

/// One run of the composer prompt in the order the user composed it: literal
/// text, or a pill referencing a selection by its runtime identity (primary
/// selector). The token field archives these so the prompt survives view
/// recreation, and the prompt formatter ships them so agents see where each
/// selection sits inside the instruction.
public enum BrowserDesignModePromptRun: Equatable, Sendable {
    case text(String)
    case token(String)
}
