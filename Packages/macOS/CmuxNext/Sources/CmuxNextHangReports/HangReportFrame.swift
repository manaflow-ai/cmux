/// One call-stack frame as a report sends it: the image's name, its UUID and the offset into its
/// `__TEXT` segment, enough to symbolicate with the image's dSYM and nothing more.
///
/// A frame in an image that is neither ours nor Apple's is ``other``: no name, UUID or offset,
/// so an input method, plug-in or injected library is never named.
public nonisolated struct HangReportFrame: Codable, Sendable, Hashable {
    /// The image's file name (`AppKit`, `cmux NEXT Nightly`), or `other`.
    public var image: String
    /// The image's `LC_UUID`, uppercase; nil for ``other``.
    public var uuid: String?
    /// Return address minus the image's load address (MetricKit's
    /// `offsetIntoBinaryTextSegment`); nil for ``other``.
    public var offset: UInt64?

    /// The image name of a frame that is not ours or Apple's.
    public static let otherImage = "other"
    /// A frame that is not ours or Apple's.
    public static let other = HangReportFrame(image: otherImage, uuid: nil, offset: nil)

    /// Makes the value from its parts.
    public init(image: String, uuid: String?, offset: UInt64?) {
        self.image = image
        self.uuid = uuid
        self.offset = offset
    }

    /// Whether this frame names no image.
    public var isOther: Bool { image == Self.otherImage }
}
