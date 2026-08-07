import Foundation

/// Selects standard browser behavior or an isolated artifact-document preview.
enum BrowserPanelContentMode {
    case standard
    case artifactHTMLPreview(documentURL: URL)

    var artifactDocumentURL: URL? {
        guard case .artifactHTMLPreview(let documentURL) = self else { return nil }
        return documentURL
    }

    var allowsSessionPersistence: Bool {
        artifactDocumentURL == nil
    }
}
