/// One Mach-O image loaded in this process: where it came from, its UUID and its `__TEXT` range.
public nonisolated struct LoadedImage: Sendable, Equatable {
    /// The path dyld loaded it from (only ``ImageClassifier`` reads it; it is never sent).
    public var path: String
    /// `LC_UUID`, uppercase.
    public var uuid: String
    /// The load address (the Mach-O header).
    public var base: UInt64
    /// The `__TEXT` segment's size.
    public var size: UInt64

    /// Makes the value from its parts.
    public init(path: String, uuid: String, base: UInt64, size: UInt64) {
        self.path = path
        self.uuid = uuid.uppercased()
        self.base = base
        self.size = size
    }

    /// Whether `address` is inside the `__TEXT` segment.
    public func contains(_ address: UInt64) -> Bool { address >= base && address < base &+ size }
}
