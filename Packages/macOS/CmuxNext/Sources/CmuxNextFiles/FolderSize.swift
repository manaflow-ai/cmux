/// The total of a folder's contents, as Get Info and "Calculate all sizes" show it.
public struct FolderSize: Sendable, Equatable {
    /// Logical bytes of every file inside.
    public var bytes: Int64
    /// Bytes on disk.
    public var allocated: Int64
    /// Items inside (files and folders, at every depth).
    public var items: Int

    /// Makes a total.
    public init(bytes: Int64 = 0, allocated: Int64 = 0, items: Int = 0) {
        self.bytes = bytes
        self.allocated = allocated
        self.items = items
    }
}
