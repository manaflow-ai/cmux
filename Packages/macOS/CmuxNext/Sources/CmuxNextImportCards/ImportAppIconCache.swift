import AppKit
import Observation

/// Source apps' icons for the import cards, as small `data:image/png` URLs (a cmux page's CSP allows `img-src
/// data:` only), from Launch Services only (no file of the app is read).
///
/// The page's host lists only read ``url(_:)``: building them (opening Settings, Add Agent from the registry)
/// never renders an icon. ``load(_:)`` renders the missing ones off the main thread, once per app, when a scan
/// lands; each one landing is an observable change, so an open Settings page re-sends its list with the icon.
/// Before, the first Settings opening rendered every icon on the main thread in the action's turn (Launch
/// Services' synchronous mach round trips and a PNG encode per app: 56 ms on the macOS 27 STRESS sweep).
@MainActor
@Observable
final class ImportAppIconCache {
    /// Points; drawn at 2x.
    nonisolated static let side: CGFloat = 32

    /// Rendered icons by bundle id; an app with no icon maps to nil.
    private(set) var urls: [String: String?] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Renders one app's icon off the main thread (tests pass a stand-in).
    @ObservationIgnored private let render: @Sendable (String) -> String?

    init(render: @escaping @Sendable (String) -> String? = ImportAppIconCache.renderLive) {
        self.render = render
    }

    /// The icon of `bundleID` when it is rendered, else nil. Never renders.
    func url(_ bundleID: String) -> String? {
        urls[bundleID] ?? nil
    }

    /// Renders the icons of `bundleIDs` not rendered or rendering yet, off the main thread; each lands in
    /// ``urls`` when it is done.
    func load(_ bundleIDs: some Sequence<String>) {
        let missing = Set(bundleIDs).subtracting(urls.keys).subtracting(loading)
        guard !missing.isEmpty else { return }
        loading.formUnion(missing)
        let render = render
        // task-owner: one render per app, at most once per launch; results land on the main actor.
        Task.detached(priority: .utility) { [weak self] in
            for bundleID in missing.sorted() {
                let url = render(bundleID)
                await self?.land(bundleID, url)
            }
        }
    }

    private func land(_ bundleID: String, _ url: String?) {
        loading.remove(bundleID)
        urls[bundleID] = .some(url)
    }

    /// Launch Services' icon of the app, drawn into a bitmap of its own (no shared graphics state), as PNG.
    nonisolated static func renderLive(_ bundleID: String) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        let pixels = Int(side * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}
