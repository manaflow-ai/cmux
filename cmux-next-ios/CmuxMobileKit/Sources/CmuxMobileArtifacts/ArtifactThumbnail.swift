#if os(iOS)
import AVFoundation
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UIKit
import WebKit

/// What a grid tile shows for an artifact (SPEC 19, as in the ChatGPT Library): a picture
/// (image, HTML snapshot, PDF first page, video frame) or a text excerpt (code, markdown,
/// text). `nil` from `make` means nothing could be rendered: the tile keeps its type icon.
enum ArtifactThumbnail: Equatable {
    case picture(UIImage)
    case excerpt(String)

    /// Pixels on the long side of a picture thumbnail.
    static let pixelSize = CGSize(width: 360, height: 360)

    static func excerpt(of text: String) -> String? { TerminalArtifact.thumbnailExcerpt(text) }

    @MainActor
    static func make(for artifact: TerminalArtifact, content: ArtifactContent) async -> ArtifactThumbnail? {
        switch content {
        case .image(let data):
            return UIImage(data: data)?.preparingThumbnail(of: pixelSize).map(ArtifactThumbnail.picture)
        case .pdf(let data):
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            return .picture(page.thumbnail(of: pixelSize, for: .mediaBox))
        case .file(let url):
            return await videoFrame(url).map(ArtifactThumbnail.picture)
        case .text(let text):
            if artifact.kind == .html {
                return await HTMLSnapshotter().snapshot(html: text).map(ArtifactThumbnail.picture)
            }
            return excerpt(of: text).map(ArtifactThumbnail.excerpt)
        case .quickLook(let url):
            let request = QLThumbnailGenerator.Request(fileAt: url, size: pixelSize, scale: 1, representationTypes: .thumbnail)
            return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)).map { .picture($0.uiImage) }
        case .web, .directory, .binary:
            // Links are remote pages (no fetch for a thumbnail); folders and binaries have no picture.
            return nil
        }
    }

    private static func videoFrame(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = pixelSize
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Renders an HTML string off screen in a phone-width page and snapshots its top.
@MainActor
private final class HTMLSnapshotter: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Bool, Never>?

    func snapshot(html: String) async -> UIImage? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // No scripts in a thumbnail: a static first paint is enough.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 390), configuration: configuration)
        web.navigationDelegate = self
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            finished = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        guard loaded else { return nil }
        let options = WKSnapshotConfiguration()
        options.rect = web.bounds
        options.snapshotWidth = NSNumber(value: Double(ArtifactThumbnail.pixelSize.width / UIScreen.main.scale))
        return try? await web.takeSnapshot(configuration: options)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { resume(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { resume(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { resume(false) }
    }

    private func resume(_ ok: Bool) {
        finished?.resume(returning: ok)
        finished = nil
    }
}

/// Thumbnails already made this session, by artifact.
@MainActor
final class ArtifactThumbnailCache {
    static let shared = ArtifactThumbnailCache()
    private var made: [TerminalArtifact: ArtifactThumbnail] = [:]
    private var failed: Set<TerminalArtifact> = []

    func thumbnail(for artifact: TerminalArtifact, source: any ArtifactSource) async -> ArtifactThumbnail? {
        if let made = made[artifact] { return made }
        if failed.contains(artifact) { return nil }
        guard let content = try? await source.load(artifact),
              let thumbnail = await ArtifactThumbnail.make(for: artifact, content: content) else {
            failed.insert(artifact)
            return nil
        }
        made[artifact] = thumbnail
        return thumbnail
    }
}
#endif
