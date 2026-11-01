import AppKit

/// An attachment source's app icon for its chip's corner (`attachment.sourceIcon {bundleId}`): a
/// small PNG data URL (the page reads no file, CSP `img-src data:`), drawn once per app and kept
/// for the app's life (a few apps, a few KB each). An app that is not installed on this Mac has no
/// icon: the chip then wears none, as for an unknown source.
///
/// Only the apps this Mac itself said an attachment came from (``noteAnswered(_:)``: a drop's or
/// paste's source, and cmux for its own captures) have an icon. Any other id answers none, so a page
/// can't ask whether an app it names is installed. They are kept across launches, so a reopened
/// chat's chips keep theirs. Each pane's model owns one (``AgentPaneModel/sourceIcons``); the
/// answered apps are kept in `defaults`, so every pane draws the same ones.
@MainActor final class AttachmentSourceIcons {
    /// Pixels a side: the corner icon is at most 20pt, drawn at 2x and then some.
    nonisolated static let side = 64
    /// The most apps kept; past it the cache starts over (a person's sources are a handful).
    nonisolated static let limit = 128

    /// Where the answered apps are kept.
    nonisolated static let answeredKey = "attachmentSource.answeredApps"

    private var cache: [String: String?] = [:]
    private let workspace: NSWorkspace
    private let defaults: UserDefaults
    private let ownBundleId: String?

    init(workspace: NSWorkspace = .shared, defaults: UserDefaults = .standard,
         ownBundleId: String? = Bundle.main.bundleIdentifier) {
        (self.workspace, self.defaults, self.ownBundleId) = (workspace, defaults, ownBundleId)
    }

    /// The apps this Mac said attachments came from, oldest first.
    private var answered: [String] { defaults.stringArray(forKey: Self.answeredKey) ?? [] }

    /// Records that this Mac said an attachment came from `bundleId`, so its icon may be drawn.
    func noteAnswered(_ bundleId: String) {
        guard bundleId != ownBundleId else { return }
        var apps = answered.filter { $0 != bundleId }
        apps.append(bundleId)
        defaults.set(Array(apps.suffix(Self.limit)), forKey: Self.answeredKey)
    }

    /// The data URL of `bundleId`'s icon, or nil when this Mac never said an attachment came from
    /// it, or no such app is installed.
    func dataURL(_ bundleId: String) -> String? {
        guard bundleId == ownBundleId || answered.contains(bundleId) else { return nil }
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
