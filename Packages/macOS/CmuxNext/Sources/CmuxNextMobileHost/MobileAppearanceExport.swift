import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The backdrop this Mac shows, for its phones (`appearance-v1`, cmux-next-ios/PROTOCOL.md
/// "Appearance"). Only the app can resolve `appearance.background` (daily, desktop, a folder
/// shuffle, bundled art), so whenever the app scope's picture changes this exports it once (long
/// side at most 2560 px, never upscaled, JPEG 0.85) as `mobile-appearance/<sha256>.jpg` under the
/// app's Application Support folder and tells the daemon with `set-appearance-background`; the
/// daemon keeps it in memory only, so it is sent again on every (re)connection. cmux-mobile-host
/// serves the file to a phone by its hash (`appearance-asset`); the path never leaves this Mac.
final class MobileAppearanceExport: ThemeResponsive {
    /// The exported picture, as `set-appearance-background` carries it.
    nonisolated struct Exported: Encodable, Sendable, Equatable {
        let path: String
        let sha256: String
        let width: Int
        let height: Int
        let luminance: Double
    }

    /// `set-appearance-background {background}`; nil clears it (no picture shown).
    nonisolated struct BackgroundRequest: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let command = "set-appearance-background"
        static let requiredCapability: String? = "appearance-v1"
        let background: Exported?
    }

    /// Longest side of an exported picture, in pixels.
    nonisolated static let maximumSide = 2560
    /// Pictures kept in the folder (the shown one and the ones before it), so a phone fetching
    /// the previous one as it changes still finds it; older ones are removed.
    nonisolated static let keptFiles = 3

    private let daemon: DaemonService
    private let folder: URL
    /// The file the last export read, `none` without a picture.
    private var shownSource: String?
    private var exported: Exported?
    private var exporting: Task<Void, Never>?
    private var following: Task<Void, Never>?

    /// - Parameters:
    ///   - daemon: The app's local daemon.
    ///   - folder: `<Application Support>/<bundle id>/mobile-appearance`.
    init(daemon: DaemonService, folder: URL) {
        self.daemon = daemon
        self.folder = folder
    }

    func start() {
        ThemeScope.app.addResponder(self)
        themeDidChange()
        let daemon = daemon
        // task-owner: the theme coordinator (lives as long as the app); event-driven (Observation).
        // A restarted daemon forgot the background: send it on every connection.
        following = Task { [weak self] in
            for await (state, _) in ObservationStream({ (daemon.store.connectionState, daemon.store.connectionEpoch) }) {
                guard case .connected = state else { continue }
                self?.send()
            }
        }
    }

    /// The app scope repainted: export its picture when it is another one.
    func themeDidChange() {
        let url = ThemeScope.app.backdropSelection.flatMap { $0.isVideo ? nil : $0.resolvedImageURL() }
        // Another picture is another file (a desktop picture, the day's work); an export of the
        // same one is a no-op on the daemon (same hash).
        let source = url?.path ?? "none"
        guard source != shownSource else { return }
        shownSource = source
        exporting?.cancel()
        let folder = folder
        exporting = Task { [weak self] in
            var exported: Exported?
            if let url {
                // Decode, scale, encode and hash off the main actor.
                exported = await Task.detached(priority: .utility) { Self.export(url, into: folder) }.value
            }
            guard !Task.isCancelled, let self else { return }
            self.exported = exported
            self.send()
        }
    }

    private func send() {
        guard let connection = daemon.connection else { return }
        let request = BackgroundRequest(background: exported)
        Task {
            // A daemon without `appearance-v1` refuses it before sending (`missingCapabilities`).
            _ = try? await connection.request(request)
        }
    }

    /// Writes `url`'s picture as `<sha256>.jpg` in `folder`; nil when it does not decode.
    nonisolated static func export(_ url: URL, into folder: URL) -> Exported? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = jpeg(image) else { return nil }
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = folder.appending(path: "\(sha256).jpg")
        do {
            try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.checked.fileExists(atPath: file.path) { try data.blockingWrite(to: file, options: .atomic) }
        } catch {
            return nil
        }
        prune(folder, keeping: file)
        return Exported(path: file.path, sha256: sha256, width: image.width, height: image.height,
                        luminance: luminance(image))
    }

    nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Average relative luminance (Rec. 709 over linear sRGB) of the picture drawn at 16 x 16.
    nonisolated static func luminance(_ image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0.5 }
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1]) + 0.0722 * linear(pixels[index + 2])
        }
        return min(max(total / Double(side * side), 0), 1)
    }

    /// Removes exported pictures beyond the newest ``keptFiles`` (never `keeping`).
    nonisolated static func prune(_ folder: URL, keeping: URL) {
        let manager = FileManager.checked
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let dated = files.filter { $0.pathExtension == "jpg" && $0.lastPathComponent != keeping.lastPathComponent }
            .map { ($0, (try? $0.blockingResourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (file, _) in dated.dropFirst(keptFiles - 1) { try? manager.removeItem(at: file) }
    }
}
