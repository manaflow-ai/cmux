import Foundation

/// Why a dotenv line was refused, with the 1-based line. Never carries a value.
public struct CloudSecretDotenvError: Error, Equatable, Sendable, LocalizedError {
    public enum Reason: Equatable, Sendable {
        /// The line is not `KEY=VALUE`.
        case expectedAssignment
        /// The key is not a valid variable name; the payload is the key.
        case invalidName(String)
        /// A quoted value is not closed on its line. Multi-line values cannot be delivered.
        case multilineValue(String)
        /// `KEY=` with nothing after it. Only ``CloudSecretDotenv/parseLenient(_:)``
        /// reports this; the strict parser returns the empty value for validation.
        case emptyValue(String)
    }

    /// 1-based line number.
    public let line: Int
    public let reason: Reason

    public init(line: Int, reason: Reason) {
        self.line = line
        self.reason = reason
    }

    /// The variable name, when the line has a valid one. nil for a line that is not
    /// `NAME=value` or whose name is invalid: that text may be part of a value (a bare
    /// token, a wrapped line), so it is never shown.
    public var name: String? {
        switch reason {
        case .expectedAssignment, .invalidName: return nil
        case .multilineValue(let name), .emptyValue(let name): return name
        }
    }

    /// Why the line was skipped, as a short phrase with no line text: "not NAME=value",
    /// "empty value". The sheet and the CLI put the line number around it.
    public var skipReason: String {
        switch reason {
        case .expectedAssignment:
            return String(localized: "cloudSecrets.dotenv.skip.expectedAssignment", defaultValue: "not NAME=value")
        case .invalidName:
            return String(localized: "cloudSecrets.dotenv.skip.invalidName", defaultValue: "invalid variable name")
        case .multilineValue:
            return String(localized: "cloudSecrets.dotenv.skip.multilineValue", defaultValue: "value spans several lines")
        case .emptyValue:
            return String(localized: "cloudSecrets.dotenv.skip.emptyValue", defaultValue: "empty value")
        }
    }

    public var errorDescription: String? {
        switch reason {
        case .expectedAssignment:
            return String(format: String(localized: "cloudSecrets.dotenv.expectedAssignment", defaultValue: "Line %ld: expected KEY=VALUE."), line)
        case .invalidName(let name):
            return String(format: String(localized: "cloudSecrets.dotenv.invalidName", defaultValue: "Line %1$ld: “%2$@” is not a valid variable name."), line, name)
        case .multilineValue(let name):
            return String(format: String(localized: "cloudSecrets.dotenv.multilineValue", defaultValue: "Line %1$ld: the value of %2$@ spans several lines, which Cloud Secrets does not support."), line, name)
        case .emptyValue(let name):
            return String(format: String(localized: "cloudSecrets.dotenv.emptyValue", defaultValue: "Line %1$ld: %2$@ has an empty value."), line, name)
        }
    }
}
