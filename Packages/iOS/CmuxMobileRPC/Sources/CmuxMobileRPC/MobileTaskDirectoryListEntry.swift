import Foundation

/// One directly browsable child directory returned by `mobile.directory.list`.
public struct MobileTaskDirectoryListEntry: Decodable, Equatable, Sendable {
    /// The final path component shown to the user.
    public let name: String

    /// The absolute Mac path to pass in the next directory-list request.
    public let path: String

    /// Whether the child is hidden according to the Mac filesystem.
    public let isHidden: Bool

    /// Whether the child is a directory package such as an app bundle.
    public let isPackage: Bool

    /// Whether the child path is a symbolic link whose destination is a directory.
    public let isSymbolicLink: Bool

    /// Whether the Mac reports the child path as readable before navigation.
    public let isReadable: Bool

    /// Creates a validated directly browsable directory entry.
    ///
    /// - Parameters:
    ///   - name: A nonempty path component no larger than 1,024 UTF-8 bytes.
    ///   - path: An absolute Mac path no larger than 4,096 UTF-8 bytes.
    ///   - isHidden: Whether the filesystem marks the directory hidden.
    ///   - isPackage: Whether the directory is a package.
    ///   - isSymbolicLink: Whether the path is a symbolic link to a directory.
    ///   - isReadable: Whether the Mac reports the directory as readable.
    /// - Returns: An entry, or `nil` when its name or path violates the wire contract.
    public init?(
        name: String,
        path: String,
        isHidden: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isReadable: Bool
    ) {
        guard Self.isValidName(name), Self.isValidAbsolutePath(path) else {
            return nil
        }
        self.name = name
        self.path = path
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case isHidden = "is_hidden"
        case isPackage = "is_package"
        case isSymbolicLink = "is_symbolic_link"
        case isReadable = "is_readable"
    }

    /// Decodes and validates one directory entry from a response page.
    ///
    /// - Parameter decoder: The decoder containing the wire entry.
    /// - Throws: ``DecodingError/dataCorrupted(_:)`` when a name or path exceeds its wire limit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let path = try container.decode(String.self, forKey: .path)
        let isHidden = try container.decode(Bool.self, forKey: .isHidden)
        let isPackage = try container.decode(Bool.self, forKey: .isPackage)
        let isSymbolicLink = try container.decode(Bool.self, forKey: .isSymbolicLink)
        let isReadable = try container.decode(Bool.self, forKey: .isReadable)
        guard let entry = Self(
            name: name,
            path: path,
            isHidden: isHidden,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isReadable: isReadable
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Directory-list entry fields are outside the wire contract."
                )
            )
        }
        self = entry
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) {
            return true
        }
        if rhs.name.utf8.lexicographicallyPrecedes(lhs.name.utf8) {
            return false
        }
        return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            name.utf8.count <= 1_024 && !name.contains("/") &&
            !name.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func isValidAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096 &&
            !path.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
