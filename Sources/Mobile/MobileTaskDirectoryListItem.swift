import Foundation

/// One direct child directory and its navigation-relevant filesystem metadata.
struct MobileTaskDirectoryListItem: Equatable, Sendable {
    let name: String
    let path: String
    let isHidden: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) {
            return true
        }
        if rhs.name.utf8.lexicographicallyPrecedes(lhs.name.utf8) {
            return false
        }
        return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
    }
}
