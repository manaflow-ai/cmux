/// What Make Alias makes.
public enum LinkKind: Sendable, Equatable {
    /// A Finder alias (a bookmark file that follows the item when it moves).
    case alias
    /// A symbolic link to the item's path.
    case symlink
}
