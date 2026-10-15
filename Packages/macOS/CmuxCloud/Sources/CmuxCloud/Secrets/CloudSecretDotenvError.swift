import Foundation

/// Why a dotenv file was refused, with the 1-based line. Never carries a value.
public struct CloudSecretDotenvError: Error, Equatable, LocalizedError {
    public enum Reason: Equatable, Sendable {
        /// The line is not `KEY=VALUE`.
        case expectedAssignment
        /// The key is not a valid variable name; the payload is the key.
        case invalidName(String)
        /// A quoted value is not closed on its line. Multi-line values cannot be delivered.
        case multilineValue(String)
    }

    /// 1-based line number.
    public let line: Int
    public let reason: Reason

    public init(line: Int, reason: Reason) {
        self.line = line
        self.reason = reason
    }

    public var errorDescription: String? {
        switch reason {
        case .expectedAssignment:
            return String(format: String(localized: "cloudSecrets.dotenv.expectedAssignment", defaultValue: "Line %ld: expected KEY=VALUE."), line)
        case .invalidName(let name):
            return String(format: String(localized: "cloudSecrets.dotenv.invalidName", defaultValue: "Line %1$ld: “%2$@” is not a valid variable name."), line, name)
        case .multilineValue(let name):
            return String(format: String(localized: "cloudSecrets.dotenv.multilineValue", defaultValue: "Line %1$ld: the value of %2$@ spans several lines, which Cloud Secrets does not support."), line, name)
        }
    }
}
