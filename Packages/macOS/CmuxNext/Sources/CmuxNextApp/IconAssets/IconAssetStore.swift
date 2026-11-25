import CmuxNextDaemon
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CmuxNextIcons

/// Where an icon picker session stores an Image or SVG asset: the picked object's owner, its
/// daemon's blob store (`icon-assets-v1`). The daemon sanitizes and validates an SVG again and
/// returns the icon value (`image:` / `svg:sha256-<hex>`) the object's icon field then takes.
struct IconAssetStore {
    let put: @MainActor (_ mediaType: String, _ data: Data) async throws -> String

    /// The store of `daemon`, or nil when it has no blob store (an older or remote daemon): the
    /// picker then keeps its Image and SVG tabs off.
    @MainActor static func owner(_ daemon: DaemonService?) -> IconAssetStore? {
        guard let daemon, daemon.supports(DaemonCapability.iconAssets.rawValue) else { return nil }
        return IconAssetStore { [weak daemon] mediaType, data in
            guard let connection = daemon?.connection else { throw DaemonError.notConnected }
            return try await IconAssetClient(connection).put(mediaType: mediaType, data: data).icon
        }
    }
}

/// The asset kinds of the picker page (`AssetKind` in webviews/src/icon-picker/AssetTab.tsx):
/// what bytes each takes and how a downloaded file becomes one.
nonisolated enum IconAssetKind: String {
    case image
    case svg

    /// Longest side of a stored raster icon, as the page scales them (`MAX_IMAGE_SIDE`).
    static let maxImageSide = 256
    /// Largest image download read, before scaling (`MAX_IMAGE_INPUT_BYTES`).
    static let maxImageDownloadBytes = 20 * 1024 * 1024
    /// The owners' limits: an SVG icon (`MAX_SVG_ICON_BYTES`) and a stored raster (`MAX_RASTER_BYTES`).
    static let maxSVGBytes = 64 * 1024
    static let maxRasterBytes = 256 * 1024

    /// Largest download of this kind: an SVG over the owner's limit is refused before it is read.
    var maxDownloadBytes: Int {
        switch self {
        case .svg: Self.maxSVGBytes
        case .image: Self.maxImageDownloadBytes
        }
    }

    /// The media type of `data` as this kind, or nil when the bytes are not one: an SVG is text
    /// starting with `<` (the owner checks the rest); an image is PNG, JPEG or WebP by its signature.
    func mediaType(of data: Data) -> String? {
        switch self {
        case .svg:
            return IconAssetDecode.isSVGText(data) ? "image/svg+xml" : nil
        case .image:
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
                return "image/webp"
            }
            return nil
        }
    }

    /// A downloaded file as this kind: an SVG as is; an image of a type the page accepts, scaled
    /// down to ``maxImageSide`` as PNG (what the page sends for a chosen file), smaller when that
    /// PNG would not fit the owner's limit.
    func prepare(downloaded data: Data) -> (mediaType: String, data: Data)? {
        switch self {
        case .svg:
            guard data.count <= Self.maxSVGBytes else { return nil }
            return mediaType(of: data).map { ($0, data) }
        case .image:
            for side in [Self.maxImageSide, Self.maxImageSide / 2, Self.maxImageSide / 4] {
                guard let image = IconAssetDecode.thumbnail(data, types: IconAssetDecode.pickerTypes, maxPixelSize: side),
                      let png = Self.png(image) else { return nil }
                if png.count <= Self.maxRasterBytes { return ("image/png", png) }
            }
            return nil
        }
    }

    private static func png(_ image: CGImage) -> Data? {
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    /// Downloads `url` for this kind: https only, redirects too; no cookies or cache; 30 s at most;
    /// no more than ``maxDownloadBytes`` read. The page never fetches remote content; the host
    /// does, then stores what it got like a chosen file. Off the main actor: the read and the
    /// scaling never block it.
    @concurrent func download(_ url: URL) async throws -> (mediaType: String, data: Data) {
        guard url.scheme?.lowercased() == "https" else { throw IconAssetDownloadError.notHTTPS }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
        // Cancels a body still arriving when the read stops early (too large, cancelled).
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw IconAssetDownloadError.failed
        }
        let limit = maxDownloadBytes
        guard response.expectedContentLength <= limit else { throw IconAssetDownloadError.tooLarge }
        // Read up to the limit only: a server that sends more is refused, not buffered.
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw IconAssetDownloadError.tooLarge }
        }
        guard let prepared = prepare(downloaded: data) else { throw IconAssetDownloadError.notThisKind }
        return prepared
    }
}

/// Follows a redirect only to another https URL. The completion-handler form: Swift 6.3's
/// SILGen crashes on the async form's Objective-C thunk.
private nonisolated final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

nonisolated enum IconAssetDownloadError: Error {
    case notHTTPS
    case failed
    case tooLarge
    case notThisKind
}
