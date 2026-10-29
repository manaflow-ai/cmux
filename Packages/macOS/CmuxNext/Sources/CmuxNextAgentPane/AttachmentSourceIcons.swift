import AppKit

/// An attachment source's app icon for its chip's corner (`attachment.sourceIcon {bundleId}`): a
/// small PNG data URL (the page reads no file, CSP `img-src data:`), drawn once per app and kept
/// for the app's life (a few apps, a few KB each). An app that is not installed on this Mac has no
/// icon: the chip then wears none, as for an unknown source.
@MainActor final class AttachmentSourceIcons {
    static let shared = AttachmentSourceIcons()
    /// Pixels a side: the corner icon is at most 20pt, drawn at 2x and then some.
    nonisolated static let side = 64
    /// The most apps kept; past it the cache starts over (a person's sources are a handful).
    nonisolated static let limit = 128

    private var cache: [String: String?] = [:]
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    /// The data URL of `bundleId`'s icon, or nil when no such app is installed.
    func dataURL(_ bundleId: String) -> String? {
        if let kept = cache[bundleId] { return kept }
        if cache.count >= Self.limit { cache = [:] }
        let made = workspace.urlForApplication(withBundleIdentifier: bundleId).flatMap { png(of: $0) }
            .map { "data:image/png;base64,\($0.base64EncodedString())" }
        cache[bundleId] = made
        return made
    }

    private func png(of app: URL) -> Data? {
        let icon = workspace.icon(forFile: app.path)
        let side = Self.side
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
