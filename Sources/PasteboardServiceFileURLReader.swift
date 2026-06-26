import AppKit
import CmuxWindowing

/// App-target conformer of CmuxWindowing's ``ServiceFileURLReading`` seam,
/// backed by the existing app-target `PasteboardFileURLReader`.
///
/// `PasteboardFileURLReader` also feeds the terminal image-transfer path, so
/// it stays in the app target; this adapter lets the windowing-domain
/// ``ServiceOpenPasteboardResolver`` consume the same file-URL decoding behind
/// a protocol without importing the app target. It holds no state, so the
/// composition root constructs one and injects it.
struct PasteboardServiceFileURLReader: ServiceFileURLReading {
    func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
    }
}
