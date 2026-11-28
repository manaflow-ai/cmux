#if os(iOS)
import PDFKit
import SwiftUI

/// Hosts PDFKit's zoomable, scrollable document viewer for a local artifact.
struct ChatArtifactPDFView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: fileURL)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != fileURL {
            pdfView.document = PDFDocument(url: fileURL)
        }
        pdfView.autoScales = true
    }
}
#endif
