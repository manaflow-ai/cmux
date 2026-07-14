public import Foundation

/// Typed result for `mobile.directory.search`.
public struct MobileTaskDirectorySearchResponse: Decodable, Equatable, Sendable {
    public let directories: [String]

    public init(directories: [String]) {
        self.directories = Array(directories.prefix(64))
    }

    /// Decodes the Mac response and re-applies the wire cap defensively.
    public static func decode(_ data: Data) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        return Self(directories: decoded.directories.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_096
        })
    }
}
