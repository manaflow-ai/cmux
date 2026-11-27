#if os(iOS)
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UIKit
import WebKit

/// What a grid tile shows for an artifact (SPEC 19, as in the ChatGPT Library): a picture
/// (image, HTML snapshot, PDF first page, video frame) or a text excerpt (code, markdown,
/// text). `nil` from `make` means nothing could be rendered: the tile keeps its type icon.
enum ArtifactThumbnail: Equatable, @unchecked Sendable {
    case picture(UIImage)
    case excerpt(String)

    /// Pixels on the long side of a picture thumbnail.
    static let pixelSize = CGSize(width: 360, height: 360)

    static func excerpt(of text: String) -> String? { TerminalArtifact.thumbnailExcerpt(text) }

    /// Decoding and rendering run off the main thread (ImageIO downsampling, CoreGraphics PDF);
    /// only an HTML snapshot needs the main thread (WebKit), a few at a time.
    static func make(for artifact: TerminalArtifact, content: ArtifactContent, scale: CGFloat) async -> ArtifactThumbnail? {
        let thumbnail = await made(for: artifact, content: content, scale: scale)
        guard case .picture(let image)? = thumbnail else { return thumbnail }
        // In the display's own pixel format, off the main thread: an ImageIO thumbnail or a web
        // snapshot is decoded but not display-ready, and the render server converted it again each
        // time a tile scrolled in (a late frame per row of tiles).
        return await Task.detached(priority: .utility) { .picture(image.preparingForDisplay() ?? image) }.value
    }

    private static func made(for artifact: TerminalArtifact, content: ArtifactContent, scale: CGFloat) async -> ArtifactThumbnail? {
        switch content {
        case .image(let data):
            return await Task.detached(priority: .utility) { downsampled(data).map(ArtifactThumbnail.picture) }.value
        case .pdf(let data):
            return await Task.detached(priority: .utility) { pdfFirstPage(data).map(ArtifactThumbnail.picture) }.value
        case .file(let url):
            return await videoFrame(url).map(ArtifactThumbnail.picture)
        case .text(let text):
            if artifact.kind == .html {
                return await HTMLSnapshotter.snapshot(html: text, scale: scale).map(ArtifactThumbnail.picture)
            }
            return await Task.detached(priority: .utility) { excerpt(of: text).map(ArtifactThumbnail.excerpt) }.value
        case .quickLook(let url):
            let request = QLThumbnailGenerator.Request(fileAt: url, size: pixelSize, scale: 1, representationTypes: .thumbnail)
            return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)).map { .picture($0.uiImage) }
        case .ownedFile(let file, let isVideo):
            // Async thumbnail generators retain a URL, not the file's owner.
            defer { withExtendedLifetime(file) {} }
            if isVideo {
                return await videoFrame(file.url).map(ArtifactThumbnail.picture)
            }
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: pixelSize, scale: 1, representationTypes: .thumbnail)
            return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)).map { .picture($0.uiImage) }
        case .web, .directory, .binary:
            // Links are remote pages (no fetch for a thumbnail); folders and binaries have no picture.
            return nil
        }
    }

    /// An image thumbnail decoded at tile size (never the full image in memory).
    static func downsampled(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelSize.width, pixelSize.height),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    /// The first page of a PDF at tile size, drawn with CoreGraphics (thread-safe, unlike PDFKit views).
    static func pdfFirstPage(_ data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(pixelSize.width / box.width, pixelSize.height / box.height)
        let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(page)
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

/// Renders an HTML string off screen in a phone-width page and snapshots its top. At most
/// `limit` web views exist at once; a tile scrolled away before its turn never makes one.
@MainActor
final class HTMLSnapshotter: NSObject, WKNavigationDelegate {
    static let limit = 2
    private static var running = 0
    /// Tiles waiting for a slot, oldest first. A tile scrolled away (its task cancelled)
    /// leaves at once instead of holding its place until the grid rests.
    private static var waiting: [(id: UInt64, resume: CheckedContinuation<Bool, Never>)] = []
    private static var lastWaiter: UInt64 = 0
    /// Waiting tiles (tests).
    static var waitingCount: Int { waiting.count }
    /// While a grid of thumbnails moves, no snapshot starts: a web view loading and painting
    /// under a scrolling grid cost a late frame every half second, and the tiles it served
    /// had already scrolled away. Snapshots start when the grid rests, newest ask first
    /// (the tiles on screen).
    private static var paused = false

    private var finished: CheckedContinuation<Bool, Never>?
    /// Ends a load that never finishes (a stalled external resource), so its slot comes back.
    private var timeout: Task<Void, Never>?
    static let loadTimeout: Duration = .seconds(5)

    static func snapshot(html: String, scale: CGFloat) async -> UIImage? {
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await HTMLSnapshotter().snapshot(html: html, displayScale: max(scale, 1))
    }

    /// The grid moved (true) or came to rest (false).
    static func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        drain()
    }

    /// Takes a slot (true), or false when the task was cancelled while it waited.
    private static func acquire() async -> Bool {
        if !paused, running < limit, waiting.isEmpty {
            running += 1
            return true
        }
        lastWaiter &+= 1
        let id = lastWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in leave(id) }
        }
    }

    /// A cancelled waiter leaves the queue without a slot.
    private static func leave(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(returning: false)
    }

    private static func release() {
        running -= 1
        drain()
    }

    /// Hands free slots to the newest waiters while nothing moves.
    private static func drain() {
        while !paused, running < limit, !waiting.isEmpty {
            running += 1
            waiting.removeLast().resume.resume(returning: true)
        }
    }

    private func snapshot(html: String, displayScale: CGFloat) async -> UIImage? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // No scripts in a thumbnail: a static first paint is enough.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 390), configuration: configuration)
        web.navigationDelegate = self
        let loaded = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                finished = continuation
                web.loadHTMLString(html, baseURL: nil)
                timeout = Task { @MainActor [weak self, weak web] in
                    try? await Task.sleep(for: Self.loadTimeout)
                    guard !Task.isCancelled else { return }
                    web?.stopLoading()
                    self?.resume(false)
                }
            }
        } onCancel: {
            // The tile scrolled away: stop loading and give the slot back now.
            Task { @MainActor [weak self, weak web] in
                web?.stopLoading()
                self?.resume(false)
            }
        }
        timeout?.cancel()
        timeout = nil
        guard loaded, !Task.isCancelled else { return nil }
        let options = WKSnapshotConfiguration()
        options.rect = web.bounds
        // Off screen the web view has no window: the snapshot is sized in points for the display's scale.
        options.snapshotWidth = NSNumber(value: Double(ArtifactThumbnail.pixelSize.width / displayScale))
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

extension ArtifactThumbnail {
    /// Thumbnails made this session (about 60 picture tiles of 360 x 360 RGBA).
    static let cache = ArtifactMemo<ArtifactThumbnail>(costLimit: 32 * 1024 * 1024) { thumbnail in
        switch thumbnail {
        case .picture(let image)?: Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        case .excerpt(let text)?: text.utf8.count
        case nil: 1
        }
    }
}

extension ArtifactMemo where Value == ArtifactThumbnail {
    /// `scale`: the display's (an HTML snapshot is rendered off screen, where no window tells it).
    func thumbnail(for artifact: TerminalArtifact, source: any ArtifactSource, scale: CGFloat) async -> ArtifactThumbnail? {
        await value(for: artifact, scope: source.thumbnailCacheScope) { artifact in
            // A Mac temporarily offline, a cancelled tile or a failed link
            // throws. Keep those failures out of the shared thumbnail cache.
            // A loaded artifact with no visual representation still caches nil.
            do {
                let content = try await source.load(artifact)
                return await ArtifactThumbnail.make(for: artifact, content: content, scale: scale)
            } catch is ArtifactNotFound {
                // An authoritative missing file is a stable empty tile.
                return nil
            }
        }
    }
}

/// A new signed-in account must never inherit thumbnail bytes from a prior
/// account. In-flight makers are cancelled and cannot repopulate this cache.
public enum ArtifactThumbnailCacheLifecycle {
    public static func clearForSignOut() {
        ArtifactThumbnail.cache.clear()
    }
}
#endif
