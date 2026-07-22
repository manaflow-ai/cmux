/// App-bundle-resolved messages used by the command-palette socket domain.
///
/// The package must not resolve these keys itself because its bundle does not
/// contain the app's localization catalog.
public struct ControlCommandPaletteStrings: Sendable, Equatable {
    /// No routed app window exposes a live command palette.
    public let windowNotFound: String
    /// The request omitted its action identifier.
    public let missingCommandID: String
    /// The arguments payload was not a string-valued object.
    public let argumentsMustBeStringObject: String
    /// The action identifier is unavailable in the current context.
    public let commandNotFound: String
    /// Format string for a comma-separated list of missing arguments.
    public let missingArgumentsFormat: String
    /// Format string for a comma-separated list of unknown arguments.
    public let unknownArgumentsFormat: String
    /// Format string for a comma-separated list of invalid argument values.
    public let invalidArgumentValuesFormat: String

    /// Creates the app-resolved palette message set.
    public init(
        windowNotFound: String,
        missingCommandID: String,
        argumentsMustBeStringObject: String,
        commandNotFound: String,
        missingArgumentsFormat: String,
        unknownArgumentsFormat: String,
        invalidArgumentValuesFormat: String
    ) {
        self.windowNotFound = windowNotFound
        self.missingCommandID = missingCommandID
        self.argumentsMustBeStringObject = argumentsMustBeStringObject
        self.commandNotFound = commandNotFound
        self.missingArgumentsFormat = missingArgumentsFormat
        self.unknownArgumentsFormat = unknownArgumentsFormat
        self.invalidArgumentValuesFormat = invalidArgumentValuesFormat
    }
}
