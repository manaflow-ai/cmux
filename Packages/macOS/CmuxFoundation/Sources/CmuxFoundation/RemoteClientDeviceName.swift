import Darwin

/// A bounded, non-resolving device label for a remote connection.
///
/// This label is descriptive, never an authentication identity. Reading it must
/// work while Local Network permission is pending or denied: Foundation's
/// `ProcessInfo.hostName` calls `NSHost.name`, which can resolve local addresses.
public struct RemoteClientDeviceName: Sendable, Equatable {
    /// The `cmux-` prefix followed by at most 40 sanitized hostname characters.
    public let value: String

    /// Reads the kernel hostname without DNS, Bonjour, or a network connection.
    ///
    /// An unavailable or empty hostname produces `cmux-mac`.
    public init() {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else {
            self.init(hostName: "mac")
            return
        }
        self.init(hostName: String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ))
    }

    /// Derives the same label from a supplied hostname without reading the system.
    ///
    /// - Parameter hostName: A local hostname; its domain suffix is discarded.
    public init(hostName: String) {
        let raw = hostName.split(separator: ".").first.map(String.init) ?? "mac"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : Character("-") }
        value = "cmux-" + String(cleaned.prefix(40))
    }
}
