internal import Foundation

/// A validated iOS Simulator device identifier.
///
/// Every device-scoped `simctl` invocation in cmux carries one of these, and the
/// failable initializer only accepts a well-formed UUID string. That makes the
/// isolation rule — *cmux only ever operates on an explicit, dedicated device* —
/// a compile-time property: aliases such as `"booted"` (which would let a command
/// land on an arbitrary, possibly foreign simulator) cannot be represented.
public struct SimulatorDeviceUDID: Hashable, Sendable, RawRepresentable, Codable, CustomStringConvertible {
    /// The canonical (uppercased) UUID string used on the `simctl` command line.
    public let rawValue: String

    /// Creates a UDID from a UUID string, or fails for anything else.
    ///
    /// - Parameter rawValue: A UUID string such as
    ///   `"DCE5B544-A3A4-418D-AF1E-AC244F465CE3"`. Aliases like `"booted"` are
    ///   rejected by construction.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        self.rawValue = uuid.uuidString
    }

    public var description: String { rawValue }
}
