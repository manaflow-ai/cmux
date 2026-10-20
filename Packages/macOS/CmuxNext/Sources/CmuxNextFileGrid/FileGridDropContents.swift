public import AppKit

/// What a drop offers a ``FileGridDropImporter``: its file URLs, else a
/// picture. `NSPasteboard` is the app's; tests pass a value (a fleet ci-step
/// Mac has no pasteboard server, so a test cannot write a real pasteboard).
@MainActor
public protocol FileGridDropContents {
    /// The dropped files, in order (empty when none).
    var droppedFileURLs: [URL] { get }
    /// The dropped picture when the drop holds image data, else nil.
    var droppedImage: NSImage? { get }
    /// Whether the drop holds image data, read without decoding it.
    var holdsImage: Bool { get }
}
