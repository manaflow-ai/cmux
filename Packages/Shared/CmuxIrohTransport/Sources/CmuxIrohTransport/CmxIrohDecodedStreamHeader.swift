/// A decoded stream header and the number of prefix bytes it consumed.
public struct CmxIrohDecodedStreamHeader: Equatable, Sendable {
    /// The validated lane declaration.
    public let header: CmxIrohStreamHeader

    /// The byte offset at which application payload begins.
    public let consumedByteCount: Int

    /// Creates a decoded-header result.
    ///
    /// - Parameters:
    ///   - header: The validated stream header.
    ///   - consumedByteCount: The exact number of framing bytes consumed.
    public init(header: CmxIrohStreamHeader, consumedByteCount: Int) {
        self.header = header
        self.consumedByteCount = consumedByteCount
    }
}
