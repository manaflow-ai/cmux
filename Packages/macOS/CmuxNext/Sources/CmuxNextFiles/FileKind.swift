/// What a listed item is, as Finder groups it.
public enum FileKind: String, Sendable, Hashable, CaseIterable {
    /// A regular file.
    case file
    /// A folder that opens in place.
    case folder
    /// A folder Finder shows as one item (an app, a bundle, a `.photoslibrary`).
    case package
    /// A symbolic link (opened through its target).
    case symlink
    /// A socket, FIFO or device node.
    case other

    /// True for the kinds Finder sorts with folders when folders go first.
    public var isFolderLike: Bool { self == .folder }
}
