import CmuxHomeCore

/// What a part row shows: wrapped text, an image or video, or a file chip.
enum PartContent: Hashable, Sendable {
    case text(TextLayout)
    case media(MediaPart)
    case file(FilePart)
}

/// An image or video bubble. Its size comes from the ref's pixel size, so
/// the row is laid out before any byte arrives and never moves when they do.
struct MediaPart: Hashable, Sendable {
    var ref: AttachmentRef
    var isVideo: Bool
}

/// A file chip: type badge, name, kind and size.
struct FilePart: Hashable, Sendable {
    /// The name as drawn (middle-truncated to the chip width).
    var name: String
    /// The whole name (VoiceOver, Copy).
    var fullName: String
    var kind: String
    var size: String
    /// Up to four letters on the document icon ("PDF", "ZIP").
    var badge: String
    /// Content hash (upload progress is keyed by it).
    var hash: String

    var detail: String { kind + " \u{00B7} " + size }
}
