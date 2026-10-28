public import AppKit
import CmuxNextCompat
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture cmux shows for ``BackdropSelection/desktop``: the file macOS reports for the
/// screen when it is a readable picture, else what the desktop shows without one.
///
/// `NSWorkspace.desktopImageURL(for:)` can name a file that is gone (a deleted picture in `/tmp`),
/// a folder macOS rotates through, a `.madesktop` description or an aerial with no still. Each
/// resolves here to a decodable file, so the Settings tile and the window never show a broken
/// image: a missing file becomes a picture of the desktop's fill color, which is what macOS
/// draws behind a missing picture.
///
/// ```swift
/// let url = DesktopPicture(screen: NSScreen.main).resolvedURL()
/// ```
public nonisolated struct DesktopPicture: Sendable {
    /// The URL macOS reports for the screen; nil when it reports none.
    public let reportedURL: URL?
    /// The sRGB color macOS fills the desktop with around (or instead of) the picture, 0...1.
    public let fill: (red: Double, green: Double, blue: Double)
    /// Where the fill-color picture is written.
    public let fallbackFolder: URL

    /// A desktop picture from explicit values (tests).
    /// - Parameters:
    ///   - reportedURL: The URL macOS reports.
    ///   - fillColor: The desktop fill color; nil for a neutral grey.
    ///   - fallbackFolder: The folder for the fill-color picture.
    public init(reportedURL: URL?, fillColor: NSColor?, fallbackFolder: URL) {
        self.reportedURL = reportedURL
        let color = fillColor?.usingColorSpace(.sRGB)
        fill = color.map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) } ?? (0.18, 0.19, 0.21)
        self.fallbackFolder = fallbackFolder
    }

    /// The current desktop picture of `screen`, read from `NSWorkspace`.
    /// - Parameter screen: The screen; nil for no screen (the fill-color picture).
    @MainActor public init(screen: NSScreen?) {
        let workspace = NSWorkspace.shared
        let options = screen.flatMap { workspace.desktopImageOptions(for: $0) }
        self.init(reportedURL: screen.flatMap { workspace.desktopImageURL(for: $0) },
                  fillColor: options?[.fillColor] as? NSColor,
                  fallbackFolder: Self.defaultFallbackFolder)
    }

    private static var defaultFallbackFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("desktop-picture", isDirectory: true)
    }

    /// A decodable picture file for the desktop, in light or `dark`.
    /// - Parameter dark: Whether the app is in the dark appearance (a dynamic wallpaper's frame).
    /// - Returns: The reported picture, a picture in the reported folder, the wallpaper a
    ///   `.madesktop` describes, or a picture of the fill color; nil only when none can be written.
    public func resolvedURL(dark: Bool = false) -> URL? {
        if let reportedURL, let url = Self.picture(at: reportedURL, dark: dark) { return url }
        return fillPicture()
    }

    /// `url` when it is a picture or video that decodes, the first such file when it is a folder,
    /// or the still a macOS wallpaper description names.
    private static func picture(at url: URL, dark: Bool) -> URL? {
        guard url.isFileURL else { return nil }
        var isFolder: ObjCBool = false
        // SAFETY: fileExists writes one ObjCBool into the local `isFolder`, live for the call.
        guard unsafe FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.lazy.compactMap { decodable($0) }.first
        }
        if url.pathExtension.lowercased() == "madesktop" || url.path.contains("/Desktop Pictures/") {
            if let still = BackdropSelection.system(path: url.path).imageURL(for: dark ? .dark : .light), let file = decodable(still) {
                return file
            }
        }
        return decodable(url)
    }

    private static func decodable(_ url: URL) -> URL? {
        if AppleWallpapers.isVideo(url.path) { return FileManager.default.isReadableFile(atPath: url.path) ? url : nil }
        guard let source = CheckedImageSource(blockingContentsOf: url), source.count > 0, source.type != nil else { return nil }
        return url
    }

    /// A small PNG of the fill color, written once per color.
    private func fillPicture() -> URL? {
        let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        let hex = String(format: "%02x%02x%02x", channel(fill.red), channel(fill.green), channel(fill.blue))
        let file = fallbackFolder.appendingPathComponent("fill-\(hex).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let width = 320, height = 200
        guard let context = CGContext.pixelOwningBitmap(width: width, height: height,
                                                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        try? FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
        let partial = fallbackFolder.appendingPathComponent(UUID().uuidString + ".partial")
        guard let destination = blockingImageDestination(url: partial as CFURL, type: UTType.png.identifier as CFString, count: 1) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard blockingImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        if (try? FileManager.default.moveItem(at: partial, to: file)) == nil {
            try? FileManager.default.removeItem(at: partial)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
