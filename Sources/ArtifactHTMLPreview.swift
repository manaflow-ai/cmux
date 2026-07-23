import AppKit
import Foundation
import WebKit

struct ArtifactHTMLPreviewDocument {
    private static let maximumSourceBytes = 8 * 1024 * 1024

    let url: URL

    init(sourceURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= Self.maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let source = String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self)
        let wrapper = Self.wrapper(source: source)
        let encoded = Data(wrapper.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;base64,\(encoded)") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.url = url
    }

    private static func wrapper(source: String) -> String {
        let sourceDocument = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; navigate-to 'none'; frame-src 'self'; child-src 'self'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:">
        <style>html,body,iframe{box-sizing:border-box;width:100%;height:100%;margin:0;border:0;background:white}iframe{display:block}</style>
        </head>
        <body><iframe sandbox="" referrerpolicy="no-referrer" srcdoc="\(sourceDocument)"></iframe></body>
        </html>
        """
    }
}

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

@MainActor
enum ArtifactHTMLPreviewWebViewPolicy {
    static func makeConfiguration() -> WKWebViewConfiguration {
        makeConfiguration(websiteDataStore: .nonPersistent())
    }

    private static func makeConfiguration(
        websiteDataStore: WKWebsiteDataStore
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    static func makeWebView(websiteDataStore: WKWebsiteDataStore) -> CmuxWebView {
        let webView = CmuxWebView(
            frame: .zero,
            configuration: makeConfiguration(websiteDataStore: websiteDataStore)
        )
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        if #available(macOS 13.3, *) {
            webView.isInspectable = false
        }
        return webView
    }
}

struct ArtifactHTMLPreviewNavigationPolicy {
    let documentURL: URL

    func allowsNavigation(to url: URL?, targetIsMainFrame: Bool?) -> Bool {
        guard let url else { return false }
        switch targetIsMainFrame {
        case true:
            return url == documentURL
        case false:
            return url.absoluteString == "about:srcdoc" || url.absoluteString == "about:blank"
        case nil:
            return false
        }
    }
}
