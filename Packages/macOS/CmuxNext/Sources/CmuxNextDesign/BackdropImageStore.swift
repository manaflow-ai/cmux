public import AppKit
import ImageIO

/// Backdrop images decoded once per process and shared by every window.
///
/// The first window's painting decodes off the main actor, so launch's first
/// frame draws the theme's colors without waiting for it (a 2400 px painting
/// cost that frame about 50 ms when AppKit decoded it in the commit). Later
/// windows take the decoded image at once.
@MainActor
public final class BackdropImageStore {
    public static let shared = BackdropImageStore()

    private var images: [String: NSImage] = [:]
    private var loads: [String: Task<Decoded?, Never>] = [:]

    /// A decoded bitmap handed from the decoding task to the main actor.
    // crash-allow: immutable CGImage is transferred from the detached decoder to the main actor.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    public init() {}

    /// The decoded image of `selection`, or nil until it has loaded.
    func cached(_ selection: BackdropSelection) -> NSImage? { images[selection.id] }

    /// The decoded image of `selection`, loading it off the main actor once.
    func image(_ selection: BackdropSelection) async -> NSImage? {
        let id = selection.id
        if let image = images[id] { return image }
        let load: Task<Decoded?, Never>
        if let running = loads[id] {
            load = running
        } else {
            let url = selection.imageURL
            load = Task.detached(priority: .userInitiated) { url.flatMap(Self.decode) }
            loads[id] = load
        }
        let decoded = await load.value
        loads[id] = nil
        if let image = images[id] { return image }
        guard let decoded else { return nil }
        // Point size equals pixel size, as `NSImage(contentsOf:)` read it.
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        images[id] = image
        return image
    }

    /// Decodes the file now (not when the image first draws).
    private nonisolated static func decode(_ url: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return Decoded(image: image)
    }
}
