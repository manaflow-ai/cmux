/// Seam exposing the ``TextBoxAttachment`` carried by an app-side inline text
/// attachment.
///
/// The live inline attachment is an app-target `NSTextAttachment` subclass that
/// holds a ``TextBoxAttachment``. The attributed-string submission-parts reader
/// lives in this package and cannot name the app-private attachment class, so
/// the app conforms its inline-attachment class to this protocol and the reader
/// matches `value as? (any TextBoxInlineAttachmentCarrying)`. Because that class
/// is the only conformer, the match is identical to the legacy concrete cast.
public protocol TextBoxInlineAttachmentCarrying {
    /// The textbox attachment carried by this inline attachment.
    var textBoxAttachment: TextBoxAttachment { get }
}
