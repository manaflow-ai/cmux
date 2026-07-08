/// UI-test flags parsed from an explicit environment dictionary.
public struct UITestEnvironmentConfig: Equatable, Sendable {
    private let environment: [String: String]

    /// Creates a UI-test config from explicit environment values.
    ///
    /// - Parameter environment: Process-style environment keys and values.
    public init(environment: [String: String]) {
        self.environment = environment
    }

}
