public import AppKit

/// Reads file URLs carried directly on an `NSPasteboard` (the `.fileURL`
/// types, the legacy `NSFilenamesPboardType` property list, and a raw
/// `.fileURL` string), de-duplicated and standardized.
///
/// This is the seam ``ServiceOpenPasteboardResolver`` calls before its
/// raw-string fallback. It exists so the resolution orchestration (the
/// empty-check and newline-split fallback) lives in ``CmuxWindowing`` while
/// the concrete pasteboard-object decoding stays in the app target, where
/// the same reader (`PasteboardFileURLReader`) also serves the terminal
/// image-transfer path. The app target supplies the conforming type at the
/// composition root; tests inject a fake that returns fixed URLs.
@MainActor
public protocol ServiceFileURLReading {
    /// Returns the ordered, de-duplicated file URLs carried directly on
    /// `pasteboard`, or an empty array when the pasteboard has no file-URL
    /// representation.
    /// - Parameter pasteboard: The Finder NSServices pasteboard.
    /// - Returns: The standardized file URLs, in pasteboard order with
    ///   duplicates removed.
    func fileURLs(from pasteboard: NSPasteboard) -> [URL]
}
