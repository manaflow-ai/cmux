import AppKit
import CmuxNextCompat

/// The icon of a grant row: System Settings' full-color Accessibility icon,
/// read and drawn into a bitmap at the row's size off the main thread, once
/// per window (`Cache`). Screenshots is the `camera.viewfinder` symbol with no
/// tile behind it (the Screenshot app's icon sits on an opaque white tile). A
/// Mac without the icon file gets the grant's SF Symbol too.
enum ComputerUseGrantIcon {
    enum Look: Sendable {
        case image(CGImage)
        case symbol(String)
    }

    /// The icon's side in points; the bitmap is drawn at 2x.
    nonisolated static let side: CGFloat = 56

    /// Where macOS keeps the grant's icon, in order; the first file on disk wins.
    static func paths(_ pane: ComputerUsePermissionPane) -> [String] {
        switch pane {
        case .accessibility: ["/System/Library/ExtensionKit/Extensions/AccessibilitySettingsExtension.appex",
                              "/System/Library/CoreServices/AccessibilityUIServer.app"]
        case .screenRecording: []
        }
    }

    /// The SF Symbol shown when no icon file is on disk.
    static func symbol(_ pane: ComputerUsePermissionPane) -> String {
        switch pane {
        case .accessibility: "accessibility"
        case .screenRecording: "camera.viewfinder"
        }
    }

    /// The icons one setup window shows, each read once (the window owns it).
    final class Cache {
        private var looks: [ComputerUsePermissionPane: Look] = [:]

        /// The icon if it is already loaded, else nil. Never reads a file.
        func cached(_ pane: ComputerUsePermissionPane) -> Look? { looks[pane] }

        /// The icon of `pane`, from the cache or read off the main thread.
        func load(_ pane: ComputerUsePermissionPane) async -> Look {
            if let look = looks[pane] { return look }
            let look = await ComputerUseGrantIcon.look(paths: ComputerUseGrantIcon.paths(pane),
                                                       symbol: ComputerUseGrantIcon.symbol(pane))
            looks[pane] = look
            return look
        }
    }

    /// The first of `paths` that is on disk, drawn; `symbol` when none is.
    @concurrent nonisolated static func look(paths: [String], symbol: String) async -> Look {
        for path in paths where FileManager.checked.fileExists(atPath: path) {
            if let image = render(path) { return .image(image) }
        }
        return .symbol(symbol)
    }

    /// Launch Services' icon of the file, drawn into a bitmap of its own (no shared graphics state).
    private nonisolated static func render(_ path: String) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: path)
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
        return bitmap.cgImage
    }
}
