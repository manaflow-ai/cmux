import AppKit
import Darwin
import Foundation
import WebKit

struct ArtifactHTMLPreviewDocument: Sendable {
    private static let maximumSourceBytes = 8 * 1024 * 1024

    let url: URL

    @concurrent
    static func load(sourceURL: URL) async throws -> ArtifactHTMLPreviewDocument {
        try ArtifactHTMLPreviewDocument(sourceURL: sourceURL)
    }

    private init(sourceURL: URL) throws {
        let source = String(decoding: try Self.readSource(sourceURL), as: UTF8.self)
        let wrapper = Self.wrapper(source: source)
        let encoded = Data(wrapper.utf8).base64EncodedString()
        guard let url = URL(string: "data:text/html;base64,\(encoded)") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.url = url
    }

    private static func readSource(_ sourceURL: URL) throws -> Data {
        try Task.checkCancellation()
        let descriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        guard status.st_size <= maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }

        var data = Data()
        data.reserveCapacity(min(Int(status.st_size), maximumSourceBytes))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumSourceBytes + 1))
        while data.count <= maximumSourceBytes {
            try Task.checkCancellation()
            let requested = min(buffer.count, maximumSourceBytes + 1 - data.count)
            guard requested > 0 else { break }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumSourceBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
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
