import Foundation

/// Returns one stable lowercase spelling for a UUID device identifier.
///
/// Device identifiers outside the UUID grammar are opaque protocol values and
/// are returned byte-for-byte, including their original case and whitespace.
// lint:allow free-function - public cross-package canonicalization API, keep source compatibility.
public func cmxCanonicalDeviceID(_ deviceID: String) -> String {
    guard let uuid = UUID(uuidString: deviceID) else { return deviceID }
    return uuid.uuidString.lowercased()
}
