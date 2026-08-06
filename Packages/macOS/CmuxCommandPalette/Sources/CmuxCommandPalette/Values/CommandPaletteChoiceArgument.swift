/// One finite-choice argument collected before a palette command runs.
public struct CommandPaletteChoiceArgument: Sendable, Equatable {
    /// One stable value and its localized label.
    public typealias Choice = CommandPaletteChoice

    /// Stable key used in the handler's value dictionary.
    public let name: String
    /// Localized label describing the requested value.
    public let title: String
    /// Finite values accepted for this argument.
    public let choices: [Choice]

    /// Creates one finite-choice command argument.
    /// - Parameters:
    ///   - name: Stable key used in the handler's value dictionary.
    ///   - title: Localized label describing the requested value.
    ///   - choices: Finite values accepted for this argument.
    public init(name: String, title: String, choices: [Choice]) {
        self.name = name
        self.title = title
        self.choices = choices
    }
}
