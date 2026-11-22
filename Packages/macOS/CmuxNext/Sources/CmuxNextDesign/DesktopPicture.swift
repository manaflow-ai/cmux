public import AppKit
public import CmuxNextDesignTokens
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
    /// How macOS places the picture on the screen (Fill, Fit, Stretch or Center).
    public let fit: BackdropArtFit
    /// The files the wallpaper store's desktop choice names (``DesktopStoreChoice/files``): which
    /// file of a reported folder shows now.
    let named: [URL]

    /// A desktop picture from explicit values (tests).
    /// - Parameters:
    ///   - reportedURL: The URL macOS reports.
    ///   - fillColor: The desktop fill color; nil for a neutral grey.
    ///   - fallbackFolder: The folder for the fill-color picture.
    ///   - fit: How macOS places the picture.
    ///   - named: The files the wallpaper store names for the desktop.
    public init(reportedURL: URL?, fillColor: NSColor?, fallbackFolder: URL, fit: BackdropArtFit = .fill, named: [URL] = []) {
        self.reportedURL = reportedURL
        let color = fillColor?.usingColorSpace(.sRGB)
        fill = color.map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) } ?? (0.18, 0.19, 0.21)
        self.fallbackFolder = fallbackFolder
        self.fit = fit
        self.named = named
    }

    /// The current desktop picture of `screen`, read from `NSWorkspace`. Both reads wait on the
    /// WindowServer, so call it off the main thread (``DesktopWallpaperWatch`` reads on its queue).
    /// - Parameters:
    ///   - screen: The screen; nil for no screen (the fill-color picture).
    ///   - named: The files the wallpaper store names for its desktop (a rotation's current one).
    public init(screen: NSScreen?, named: [URL] = []) {
        let workspace = NSWorkspace.shared
        let options = screen.flatMap { workspace.desktopImageOptions(for: $0) }
        self.init(reportedURL: screen.flatMap { workspace.desktopImageURL(for: $0) },
                  fillColor: options?[.fillColor] as? NSColor,
                  fallbackFolder: Self.defaultFallbackFolder,
                  fit: BackdropArtFit(imageScaling: (options?[.imageScaling] as? NSNumber)?.intValue,
                                      allowClipping: (options?[.allowClipping] as? NSNumber)?.boolValue),
                  named: named)
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
        if let reportedURL, let url = Self.picture(at: reportedURL, dark: dark, named: named) { return url }
        return fillPicture()
    }

    /// `url` when it is a picture or video that decodes; for a folder macOS rotates through, the
    /// one it shows now (``DesktopStoreChoice/shownFiles(in:named:)``); or the still a
    /// macOS wallpaper description names.
    private static func picture(at url: URL, dark: Bool, named: [URL]) -> URL? {
        guard url.isFileURL else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue {
            // The file the store names comes first: the folder is listed only when it names none.
            if let file = DesktopStoreChoice.shownFiles(in: url, named: named).lazy.compactMap({ decodable($0) }).first { return file }
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else { return nil }
        return url
    }

    /// A small PNG of the fill color, written once per color.
    private func fillPicture() -> URL? {
        let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        let hex = String(format: "%02x%02x%02x", channel(fill.red), channel(fill.green), channel(fill.blue))
        let file = fallbackFolder.appendingPathComponent("fill-\(hex).png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let width = 320, height = 200
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        try? FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
        let partial = fallbackFolder.appendingPathComponent(UUID().uuidString + ".partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        if (try? FileManager.default.moveItem(at: partial, to: file)) == nil {
            try? FileManager.default.removeItem(at: partial)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
