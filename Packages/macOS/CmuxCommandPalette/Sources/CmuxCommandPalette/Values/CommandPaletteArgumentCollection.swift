/// In-progress finite-choice values for one command-palette command.
public struct CommandPaletteArgumentCollection: Sendable, Equatable {
    /// The result of attempting to select the current finite choice.
    public enum SelectionResult: Sendable, Equatable {
        /// The supplied value is not declared by the current argument.
        case invalid
        /// The value was accepted and another argument remains.
        case advanced
        /// The value was accepted and all arguments are now collected.
        case completed
    }

    /// Stable identity of the command receiving the values.
    public let commandID: String
    /// Ordered argument declarations still governing this collection.
    public let arguments: [CommandPaletteChoiceArgument]
    /// Values accepted so far, keyed by argument name.
    public private(set) var values: [String: String]
    /// Index of the argument currently presented by the palette.
    public private(set) var currentArgumentIndex: Int

    /// The argument currently presented by the palette.
    public var currentArgument: CommandPaletteChoiceArgument {
        arguments[currentArgumentIndex]
    }

    /// One-based index of the current collection step.
    public var currentStep: Int { currentArgumentIndex + 1 }
    /// Total number of declared collection steps.
    public var stepCount: Int { arguments.count }

    /// Creates an in-progress collection at its first missing argument.
    ///
    /// Returns `nil` when `initialValues` already supplies every declared argument.
    /// - Parameters:
    ///   - commandID: Stable identity of the command receiving the values.
    ///   - arguments: Ordered finite-choice declarations.
    ///   - initialValues: Values already collected by an earlier step.
    public init?(
        commandID: String,
        arguments: [CommandPaletteChoiceArgument],
        initialValues: [String: String] = [:]
    ) {
        guard let firstMissingIndex = arguments.indices.first(where: { index in
            initialValues[arguments[index].name] == nil
        }) else {
            return nil
        }
        self.commandID = commandID
        self.arguments = arguments
        self.values = initialValues
        currentArgumentIndex = firstMissingIndex
    }

    /// Accepts a declared value for the current argument.
    /// - Parameter value: Stable choice value to record.
    /// - Returns: Whether the value was invalid, advanced the flow, or completed it.
    @discardableResult
    public mutating func selectCurrentChoice(value: String) -> SelectionResult {
        let argument = currentArgument
        guard argument.choices.contains(where: { $0.value == value }) else {
            return .invalid
        }
        values[argument.name] = value
        guard let nextIndex = arguments.indices.dropFirst(currentArgumentIndex + 1).first(where: { index in
            values[arguments[index].name] == nil
        }) else {
            return .completed
        }
        currentArgumentIndex = nextIndex
        return .advanced
    }
}
