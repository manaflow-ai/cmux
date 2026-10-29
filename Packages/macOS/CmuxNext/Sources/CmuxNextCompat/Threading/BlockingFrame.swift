public import Foundation

/// One return address of a blocking call's stack, as a report may carry it: the image's UUID and
/// the offset into that image, enough to symbolicate with the image's dSYM and nothing more (no
/// path, no file name, no symbol).
public struct BlockingFrame: Sendable, Hashable {
    /// The image's `LC_UUID`.
    public var imageUUID: UUID
    /// The return address minus the image's load address.
    public var offset: UInt64

    /// Makes the value from its parts.
    public init(imageUUID: UUID, offset: UInt64) {
        self.imageUUID = imageUUID
        self.offset = offset
    }
}
