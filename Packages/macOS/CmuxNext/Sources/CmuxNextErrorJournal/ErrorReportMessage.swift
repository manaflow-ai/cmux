/// The text of one ``ErrorReporter`` report, written like a `Logger` message:
/// `"save failed: \(error, privacy: .public)"`.
///
/// As `Logger` treats them, an interpolated string or object with no `privacy:` is private
/// (`<private>`), and numbers and Booleans are public; so a `Logger.error` call moves to a
/// reporter with its text unchanged and shows no more than it did.
public struct ErrorReportMessage: ExpressibleByStringInterpolation, Sendable {
    /// The text, each private value replaced by `<private>`.
    public let text: String

    /// A message with no interpolated values.
    public init(stringLiteral value: String) {
        text = value
    }

    /// A message built by string interpolation.
    public init(stringInterpolation: Interpolation) {
        text = stringInterpolation.text
    }

    /// Builds an ``ErrorReportMessage`` from its literal parts and values.
    public struct Interpolation: StringInterpolationProtocol {
        var text = ""

        /// Starts an empty message.
        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        /// Appends literal text.
        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        /// Appends a value; private unless `privacy` is ``ErrorReportPrivacy/public``.
        public mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: ErrorReportPrivacy = .private) {
            append(value.description, privacy)
        }

        /// Appends an error's description; private unless `privacy` is ``ErrorReportPrivacy/public``.
        public mutating func appendInterpolation(_ error: any Error, privacy: ErrorReportPrivacy = .private) {
            append(String(describing: error), privacy)
        }

        /// Appends an integer; public unless `privacy` is ``ErrorReportPrivacy/private``.
        public mutating func appendInterpolation(_ value: some BinaryInteger, privacy: ErrorReportPrivacy = .public) {
            append(value.description, privacy)
        }

        /// Appends a number; public unless `privacy` is ``ErrorReportPrivacy/private``.
        public mutating func appendInterpolation(_ value: Double, privacy: ErrorReportPrivacy = .public) {
            append(value.description, privacy)
        }

        /// Appends a Boolean; public unless `privacy` is ``ErrorReportPrivacy/private``.
        public mutating func appendInterpolation(_ value: Bool, privacy: ErrorReportPrivacy = .public) {
            append(value.description, privacy)
        }

        private mutating func append(_ value: String, _ privacy: ErrorReportPrivacy) {
            text += privacy == .public ? value : "<private>"
        }
    }
}
