import PDFKit

/// Immutable ownership transfer from the background parser to the main actor.
struct FilePreviewPDFLoadResult: @unchecked Sendable {
    let document: PDFDocument?

    init(url: URL) {
        document = PDFDocument(url: url)
    }

    @concurrent
    static func load(url: URL) async -> FilePreviewPDFLoadResult {
        FilePreviewPDFLoadResult(url: url)
    }
}
