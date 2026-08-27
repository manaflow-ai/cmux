import Foundation

/// A validated user preference for Chromium's loopback CDP listener.
///
/// Port `0` represents disabled external attachment. Positive values are valid
/// TCP ports; values outside the TCP range cannot cross this type boundary.
public struct ChromiumRemoteDebuggingPort: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// The persisted integer representation. Zero means disabled.
    public let rawValue: Int

    /// Creates a validated remote-debugging preference.
    ///
    /// - Parameter rawValue: Zero, or a TCP port in the user-port range
    ///   `1024...65535`.
    public init?(rawValue: Int) {
        guard rawValue == 0 || (1024...65_535).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// External CDP attachment is disabled.
    public static let disabled = ChromiumRemoteDebuggingPort(validatedRawValue: 0)

    /// Whether cmux should advertise the child process's loopback CDP endpoint.
    public var isExternallyAttachable: Bool { rawValue > 0 }

    /// Parses a settings or command-line integer into a validated preference.
    ///
    /// - Parameter rawValue: Text containing a base-10 port.
    /// - Returns: A validated port, or `nil` when the text is malformed or out of range.
    public static func parse(_ rawValue: String?) -> ChromiumRemoteDebuggingPort? {
        guard let rawValue,
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return ChromiumRemoteDebuggingPort(rawValue: value)
    }

    private init(validatedRawValue: Int) {
        rawValue = validatedRawValue
    }
}
