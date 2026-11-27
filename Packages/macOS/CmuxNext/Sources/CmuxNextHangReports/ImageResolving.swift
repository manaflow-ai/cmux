/// Finds the loaded image of an address or a UUID. ``DyldImageResolver`` reads this process;
/// tests pass a fixed list.
public protocol ImageResolving: Sendable {
    /// The image whose `__TEXT` holds `address`.
    func image(containing address: UInt64) -> LoadedImage?
    /// The loaded image with this UUID.
    func image(uuid: String) -> LoadedImage?
}
