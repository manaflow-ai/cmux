public import Foundation

/// The resolved, non-secret environment returned by the bundled Rust CLI.
/// The app decodes this value; Rust owns its origins, bundle policy and persistence.
public struct CloudRuntimeSelection: Decodable, Sendable, Equatable {
    public var name: String
    public var apiOrigin: URL
    public var authWebOrigin: URL
    public var vmOrigin: URL
    public var platformOrigin: URL
    public var mobileOrigin: URL
    public var deviceHubOrigin: URL
    public var shareRoomOrigin: URL
    public var shareApiOrigin: URL
    public var stackOrigin: URL
    public var stackProjectId: String
    public var stackClientKey: String
    public var bundleId: String
    public var mutable: Bool
    public var authNamespace: String
    public var legacyStorage: Bool

    /// Only an actual environment switch changes existing native credential/pairing names.
    public var storageNamespace: String? { legacyStorage ? nil : authNamespace }

    /// Decodes the CLI's JSON response without maintaining another environment table.
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}
