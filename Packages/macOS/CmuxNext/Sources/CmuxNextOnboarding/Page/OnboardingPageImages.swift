import AppKit
import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextIcons
import Observation

/// The onboarding page's icons as `data:` PNGs: agent marks, browser app icons, profile pictures,
/// the helper app's icon and the grant icons. Each is drawn once per window, off the main thread
/// (disk reads and PNG encoding); until it lands the page keeps the icon's place empty. Observable:
/// a state read that found an icon missing reads again once it lands.
@MainActor
@Observable
final class OnboardingPageImages {
    typealias Image = OnboardingPageState.Image

    private var drawn: [String: Image] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private let grantIcons = ComputerUseGrantIcon.Cache()

    /// The agent's mark (`AgentSignInSource.agentIcon`, a template image at 24 pt); the generic glyph without one.
    func agent(_ agent: OnboardingAgent, source: (any AgentSignInSource)?) -> Image? {
        let key = "agent:\(agent.id):\(agent.brand ?? "")"
        if let image = drawn[key] { return image }
        guard !pending.contains(key) else { return nil }
        let mark = source?.agentIcon(agent, side: 24)
        guard let image = mark ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil),
              let bitmap = Self.bitmap(image, side: 24) else { return nil }
        return encode(key, side: 24, template: mark == nil || image.isTemplate) { NSImage(cgImage: bitmap, size: .zero) }
    }

    /// The browser's app icon at 30 pt: its app, else one with its bundle id, else the generic glyph.
    func browser(_ browser: ImportBrowser, appURL: URL?) -> Image? {
        let key = "browser:\(browser.rawValue):\(appURL?.path ?? "")"
        if let image = drawn[key] { return image }
        guard !pending.contains(key) else { return nil }
        let bundleIDs = browser.bundleIDs
        let name = browser.displayName
        let generic = Self.bitmap(NSImage.icon(.browser, size: 30), side: 30)
        return encode(key, side: 30) {
            if let appURL { return NSWorkspace.shared.icon(forFile: appURL.path) }
            for bundleID in bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
            }
            let conventional = "/Applications/\(name).app"
            if FileManager.checked.fileExists(atPath: conventional) { return NSWorkspace.shared.icon(forFile: conventional) }
            return generic.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    /// The profile's picture at 16 pt.
    func avatar(_ url: URL) -> Image? {
        let key = "avatar:\(url.path)"
        if let image = drawn[key] { return image }
        return encode(key, side: 16) { (try? Data(blockingContentsOf: url)).flatMap(NSImage.init(data:)) }
    }

    /// The helper app's icon at 96 pt, or cmux's own until the helper is found on disk.
    func helper(_ url: URL?) -> Image? {
        let key = "helper:\(url?.path ?? "")"
        if let image = drawn[key] { return image }
        guard !pending.contains(key) else { return nil }
        let fallback = Self.bitmap(NSApp.applicationIconImage, side: 96)
        return encode(key, side: 96) {
            guard let url, FileManager.checked.fileExists(atPath: url.path) else { return fallback.map { NSImage(cgImage: $0, size: .zero) } }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    /// The grant's icon at ``ComputerUseGrantIcon/side``: System Settings' own, else its SF Symbol (tinted by the page).
    func grant(_ pane: ComputerUsePermissionPane) -> Image? {
        let key = "grant:\(pane.rawValue)"
        if let image = drawn[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let icons = grantIcons
        // task-owner: one off-main icon read per grant row, at most once per window; it only stores the image.
        Task { [weak self] in
            let look = await icons.load(pane)
            guard let self else { return }
            pending.remove(key)
            let side = ComputerUseGrantIcon.side
            switch look {
            case .image(let cgImage):
                _ = encode(key, side: side) { NSImage(cgImage: cgImage, size: .zero) }
            case .symbol(let name):
                let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
                guard let bitmap = symbol.flatMap({ Self.bitmap($0, side: side) }) else { return }
                _ = encode(key, side: side, template: true) { NSImage(cgImage: bitmap, size: .zero) }
            }
        }
        return nil
    }

    /// Draws `make()` at `side` points (2x) off the main thread, keeps it under `key`, where an
    /// observing read finds it. Nil now; the drawn image on a later read.
    /// `template`: the page tints it (nil: the drawn image says).
    private func encode(_ key: String, side: CGFloat, template: Bool? = nil, _ make: @escaping @Sendable () -> NSImage?) -> Image? {
        if let image = drawn[key] { return image }
        guard pending.insert(key).inserted else { return nil }
        // task-owner: one off-main draw per icon key, at most once per window; it only stores the image.
        Task { [weak self] in
            let image = await Self.draw(make, side: side, template: template)
            guard let self else { return }
            pending.remove(key)
            guard let image else { return }
            drawn[key] = image
        }
        return nil
    }

    /// A main-actor image (a symbol, an agent mark) as a bitmap at `side` points (2x), to draw off the main thread.
    private static func bitmap(_ image: NSImage, side: CGFloat) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    @concurrent nonisolated private static func draw(_ make: @Sendable () -> NSImage?, side: CGFloat, template: Bool?) async -> Image? {
        guard let image = make() else { return nil }
        let pixels = Int(side * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return Image(src: "data:image/png;base64," + png.base64EncodedString(), template: template ?? image.isTemplate)
    }
}
