import AppKit
import PDFKit

nonisolated enum FilePreviewDocumentLoader {
    static func loadPDFDocument(at url: URL) -> PDFDocument? {
        PDFDocument(url: url)
    }

    static func loadImageData(at url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func pageRotations(in document: PDFDocument?) -> [Int: Int] {
        guard let document else { return [:] }
        var rotations: [Int: Int] = [:]
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            rotations[pageIndex] = page.rotation
        }
        return rotations
    }

    static func applyPageRotations(_ rotations: [Int: Int], to document: PDFDocument) {
        guard !rotations.isEmpty else { return }
        for (pageIndex, rotation) in rotations where pageIndex >= 0 && pageIndex < document.pageCount {
            document.page(at: pageIndex)?.rotation = rotation
        }
    }
}
