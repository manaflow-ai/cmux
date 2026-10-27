/// What Make Alias makes.
public enum LinkKind: Sendable, Equatable {
    /// A Finder alias (a bookmark file that follows the item when it moves).
    case alias
    /// A symbolic link to the item's path.
    case symlink

    /// What the system makes for a request of `kind`: bookmark files are Apple-only, so elsewhere
    /// an alias is the nearest link, a symbolic one.
    static func made(for kind: LinkKind) -> LinkKind {
        #if canImport(Darwin)
        kind
        #else
        .symlink
        #endif
    }
}
