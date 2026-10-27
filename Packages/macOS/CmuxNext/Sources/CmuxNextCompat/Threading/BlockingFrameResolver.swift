#if DEBUG || CMUX_BLOCKING_CHECKS
/// Turns return addresses into ``BlockingFrame``s (image UUID + offset) through the shared
/// ``ImageOffsetResolver``. Runs on the drain queue only (`dladdr` takes dyld's lock).
struct BlockingFrameResolver {
    #if canImport(MachO)
    private var images = ImageOffsetResolver()

    /// The frames of `addresses`; an address outside a loaded image with a UUID is left out.
    mutating func frames(_ addresses: [UInt]) -> [BlockingFrame] {
        addresses.compactMap { address in
            guard let frame = images.resolve(address), let uuid = frame.image.uuid else { return nil }
            return BlockingFrame(imageUUID: uuid, offset: UInt64(frame.offset))
        }
    }
    #else
    /// No frames: ``ImageOffsetResolver`` reads Mach-O images, so a Linux report names its site without a stack.
    mutating func frames(_ addresses: [UInt]) -> [BlockingFrame] {
        []
    }
    #endif
}
#endif
