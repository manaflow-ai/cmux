import Foundation

/// The in-progress finite-choice arguments for one command-palette action.
public struct CommandPaletteArgumentCollection: Sendable, Equatable {
    /// The result of selecting one value for the current argument.
    public enum SelectionResult: Sendable, Equatable {
        /// The value was rejected because it is not a declared choice.
        case invalid
        /// The value was accepted and another choice argument remains.
        case advanced
        /// The value was accepted and every choice argument is now populated.
        case completed
    }

    /// Stable identifier of the action being configured.
    public let commandID: String
    /// Static argument contract declared by the action.
    public let arguments: [CmuxActionArgumentDefinition]
    /// Values collected so far, keyed by stable argument name.
    public private(set) var values: [String: String]
    /// Index of the argument currently presented by the palette.
    public private(set) var currentArgumentIndex: Int

    /// The argument currently presented by the palette.
    public var currentArgument: CmuxActionArgumentDefinition {
        arguments[currentArgumentIndex]
    }

    /// One-based position of the current finite-choice argument.
    public var currentStep: Int {
        choiceArgumentIndices.firstIndex(of: currentArgumentIndex).map { $0 + 1 } ?? 1
    }

    /// Total number of finite-choice arguments in this collection.
    public var stepCount: Int { choiceArgumentIndices.count }

    /// Creates a collection positioned at the first missing finite-choice argument.
    ///
    /// Returns `nil` when no finite-choice argument needs interactive collection.
    /// - Parameters:
    ///   - commandID: Stable identifier of the action being configured.
    ///   - arguments: Static arguments declared by the action.
    ///   - initialValues: Values already supplied by the caller.
    public init?(
        commandID: String,
        arguments: [CmuxActionArgumentDefinition],
        initialValues: [String: String] = [:]
    ) {
        guard let firstMissingIndex = arguments.indices.first(where: { index in
            !arguments[index].choices.isEmpty && initialValues[arguments[index].name] == nil
        }) else {
            return nil
        }
        self.commandID = commandID
        self.arguments = arguments
        self.values = initialValues
        self.currentArgumentIndex = firstMissingIndex
    }

    /// Selects a declared value for the current argument and advances the collection.
    /// - Parameter value: Stable choice value to supply to the action.
    /// - Returns: Whether the selection was invalid, advanced, or completed.
    @discardableResult
    public mutating func selectCurrentChoice(value: String) -> SelectionResult {
        let argument = currentArgument
        guard argument.choices.contains(where: { $0.value == value }) else {
            return .invalid
        }
        values[argument.name] = value
        guard let nextIndex = arguments.indices.dropFirst(currentArgumentIndex + 1).first(where: { index in
            !arguments[index].choices.isEmpty && values[arguments[index].name] == nil
        }) else {
            return .completed
        }
        currentArgumentIndex = nextIndex
        return .advanced
    }

    private var choiceArgumentIndices: [Int] {
        arguments.indices.filter { !arguments[$0].choices.isEmpty }
    }
}
