/// An uploaded file a dispatch refers to, resolved by the Mac from its upload id.
public struct MobileTaskAttachment: Hashable, Sendable {
    /// `up_…` from C4's `files.upload` channel.
    public var upload: String
    /// Absolute path on this Mac, from C4's staging; never from the phone.
    public var path: String

    public init(upload: String, path: String) {
        self.upload = upload
        self.path = path
    }
}
