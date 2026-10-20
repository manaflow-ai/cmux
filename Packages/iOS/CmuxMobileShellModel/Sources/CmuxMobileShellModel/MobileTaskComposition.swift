import Foundation

/// The workspace-create parameters derived from a task template and prompt.
public struct MobileTaskComposition: Equatable, Sendable {
    /// Shell-interpreted command for the initial terminal, or `nil` for a plain shell.
    public var initialCommand: String?
    /// Environment variables for the initial terminal.
    public var initialEnv: [String: String]
    /// Suggested workspace title derived from the prompt.
    public var title: String?

    /// Creates a task composition.
    /// - Parameters:
    ///   - initialCommand: Shell-interpreted command for the initial terminal.
    ///   - initialEnv: Environment variables for the initial terminal.
    ///   - title: Suggested workspace title.
    public init(initialCommand: String?, initialEnv: [String: String], title: String?) {
        self.initialCommand = initialCommand
        self.initialEnv = initialEnv
        self.title = title
    }
}
