import AppKit
import PDFKit

nonisolated enum FilePreviewDocumentLoader {
    @concurrent
    static func loadPDFDocument(at url: URL) async -> PDFDocument? {
        PDFDocument(url: url)
    }

    @concurrent
    static func loadImage(at url: URL) async -> NSImage? {
        NSImage(contentsOf: url)
    }
}
