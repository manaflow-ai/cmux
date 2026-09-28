import Foundation

/// One direct child directory and its navigation-relevant filesystem metadata.
public struct MobileTaskDirectoryListItem: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isHidden: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isReadable: Bool

    public init(
        name: String,
        path: String,
        isHidden: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isReadable: Bool
    ) {
        self.name = name
        self.path = path
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
    }

    public static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) {
            return true
        }
        if rhs.name.utf8.lexicographicallyPrecedes(lhs.name.utf8) {
            return false
        }
        return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
    }
}
