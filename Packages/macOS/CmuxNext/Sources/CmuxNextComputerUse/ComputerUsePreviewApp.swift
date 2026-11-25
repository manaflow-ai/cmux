import AppKit

/// The app a Computer Use session drives, as the live preview card names and draws it: its display
/// name and its icon. The legacy helper's targets name only the app's process (no name, no bundle
/// id), so the card looks the app up itself (``ComputerUsePreviewAppResolving``).
public nonisolated struct ComputerUsePreviewApp: Equatable, Sendable {
    /// Which app: its bundle id when the driver named one, and its process.
    public struct Key: Hashable, Sendable {
        public var bundleID: String?
        public var pid: Int32?

        public init(bundleID: String?, pid: Int32?) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    /// The app's display name ("Calculator"), when found.
    public var name: String?
    /// The app's icon as a small `data:image/png;base64,` URL, when found.
    public var icon: String?

    public init(name: String?, icon: String?) {
        self.name = name
        self.icon = icon
    }
}

/// Looks an app up by bundle id or process, off the main thread. Tests pass a fake.
public nonisolated protocol ComputerUsePreviewAppResolving: Sendable {
    /// The app `key` names; nil when no app answers to it. Runs off the main thread.
    @concurrent func resolve(_ key: ComputerUsePreviewApp.Key) async -> ComputerUsePreviewApp?
}

/// ``ComputerUsePreviewAppResolving`` over AppKit: the running app of the process (its localized
/// name and bundle), else Launch Services' app of the bundle id; its icon drawn small, as PNG.
public nonisolated struct ComputerUseWorkspaceAppResolver: ComputerUsePreviewAppResolving {
    /// The icon's side in pixels: the card draws it at 40 points, 80 pixels on a Retina display.
    static let iconPixels = 96

    public init() {}

    @concurrent public func resolve(_ key: ComputerUsePreviewApp.Key) async -> ComputerUsePreviewApp? {
        var name: String?
        var url: URL?
        // A process that is gone, or now another app's (a reused pid), does not count.
        if let pid = key.pid, let running = NSRunningApplication(processIdentifier: pid),
           key.bundleID == nil || running.bundleIdentifier == key.bundleID {
            name = running.localizedName
            url = running.bundleURL
        }
        if url == nil, let bundleID = key.bundleID {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        if name?.isEmpty ?? true, let url { name = Self.bundleName(url) }
        let icon = url.flatMap(Self.icon)
        guard name?.isEmpty == false || icon != nil else { return nil }
        return ComputerUsePreviewApp(name: name?.isEmpty == false ? name : nil, icon: icon)
    }

    /// The bundle's display name, else its name, else the file name without `.app`.
    static func bundleName(_ url: URL) -> String? {
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? [:]
        let base = bundle?.infoDictionary ?? [:]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info[key] ?? base[key]) as? String, !name.isEmpty { return name }
        }
        let file = url.deletingPathExtension().lastPathComponent
        return file.isEmpty ? nil : file
    }

    /// Launch Services' icon of the app at `url`, drawn into a bitmap of its own (no shared graphics
    /// state), as a PNG `data:` URL.
    static func icon(_ url: URL) -> String? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let pixels = iconPixels
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
