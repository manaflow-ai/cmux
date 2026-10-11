public import Foundation

/// Reads files for detection. Tests pass a fixture home; nothing else.
public protocol FileReading: Sendable {
    func data(at url: URL) -> Data?
    func exists(_ url: URL) -> Bool
}

/// Answers whether a Keychain item exists, without reading its secret
/// (attributes only, so macOS shows no prompt).
public protocol KeychainProbing: Sendable {
    func hasGenericPassword(service: String) -> Bool
}

/// Answers whether a local model server responds. Bounded by a deadline.
public protocol LocalServerProbing: Sendable {
    func isReachable(_ url: URL) async -> Bool
}
