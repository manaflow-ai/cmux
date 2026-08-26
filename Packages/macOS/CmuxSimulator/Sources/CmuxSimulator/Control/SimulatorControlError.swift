import Foundation

/// A failed `simctl` invocation or response-decoding operation.
public struct SimulatorControlError: Error, LocalizedError, Equatable, Sendable {
    /// A stable category suitable for diagnostics and recovery decisions.
    public let code: String
    /// The `simctl` arguments, excluding the `xcrun` executable.
    public let arguments: [String]
    /// A concise explanation of the failure.
    public let message: String

    /// Creates a Simulator control failure.
    /// - Parameters:
    ///   - code: A stable failure category.
    ///   - arguments: The attempted `simctl` arguments.
    ///   - message: A concise diagnostic.
    public init(code: String, arguments: [String], message: String) {
        self.code = code
        self.arguments = arguments
        self.message = message
    }

    /// The diagnostic exposed through `LocalizedError`.
    public var errorDescription: String? { message }
}
