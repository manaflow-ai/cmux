/// App-bundle-localized validation messages shared by browser engine entrypoints.
public struct ControlBrowserEngineStrings: Sendable, Equatable {
    /// Message returned when an engine token is not recognized.
    public let invalidOption: String
    /// Message returned when an engine is used for a non-browser surface.
    public let browserOnly: String

    /// Creates the localized browser-engine message bundle.
    public init(invalidOption: String, browserOnly: String) {
        self.invalidOption = invalidOption
        self.browserOnly = browserOnly
    }
}
