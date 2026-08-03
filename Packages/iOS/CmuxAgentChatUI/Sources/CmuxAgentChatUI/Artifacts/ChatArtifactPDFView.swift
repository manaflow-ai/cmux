#if os(iOS)
import PDFKit

/// Native PDFKit surface for a local artifact.
@MainActor
final class ChatArtifactPDFNativeView: PDFView {
    init(fileURL: URL) {
        super.init(frame: .zero)
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        document = PDFDocument(url: fileURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fileURL: URL) {
        if document?.documentURL != fileURL {
            document = PDFDocument(url: fileURL)
        }
        autoScales = true
    }
}
#endif
