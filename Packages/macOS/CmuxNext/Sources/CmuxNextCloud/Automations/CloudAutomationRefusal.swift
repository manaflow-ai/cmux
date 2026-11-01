public import Foundation

/// A request ``CloudAutomationRelay`` refuses before any call.
public struct CloudAutomationRefusal: Error, Sendable, Equatable {
    /// The refusal code (`invalid_params`, `automation.op_not_allowed`, `automation.signed_out`).
    public let code: String
    /// Words for a person.
    public let message: String

    /// Makes a refusal.
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}
