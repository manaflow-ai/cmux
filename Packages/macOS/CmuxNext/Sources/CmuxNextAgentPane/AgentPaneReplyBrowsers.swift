public import AppKit
public import Foundation

/// The installed web browsers for a preview card's "Open in" menu (decision D6). The page gets
/// only an opaque id, a name and an icon for each; it sends back `{url, browserId}`, and the host
/// opens only an app from the list it made, only for a validated http(s) URL
/// (``AgentPaneReplyRequest/webURL(_:)``), with `NSWorkspace.open(_:withApplicationAt:)`: no
/// shell, no `open(1)`, never an app path or name from the page (unlike
/// `OpenInHandlers.applicationURL(named:)`, which takes any name).
@MainActor public protocol AgentPaneBrowserApps: AnyObject {
    /// The apps that open `https` URLs, the default first.
    func applications() -> [URL]
    func displayName(of app: URL) -> String
    /// The app's icon as PNG, about 32 px.
    func iconPNG(of app: URL) -> Data?
    func open(_ url: URL, withApplicationAt app: URL)
}

@MainActor public final class AgentPaneWorkspaceBrowsers: AgentPaneBrowserApps {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func applications() -> [URL] {
        guard let probe = URL(string: "https://example.com/") else { return [] }
        var apps = workspace.urlsForApplications(toOpen: probe)
        if let preferred = workspace.urlForApplication(toOpen: probe), let index = apps.firstIndex(of: preferred) {
            apps.insert(apps.remove(at: index), at: 0)
        }
        return apps
    }

    public func displayName(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    public func iconPNG(of app: URL) -> Data? {
        let icon = workspace.icon(forFile: app.path)
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    public func open(_ url: URL, withApplicationAt app: URL) {
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The browsers the page was last shown, by opaque id. A new list replaces the ids, so an old or
/// made-up id opens nothing.
@MainActor final class AgentPaneBrowserChoices {
    private(set) var apps: [String: URL] = [:]
    /// This app, which is never offered (its own browser pane is the menu's first item).
    var ownBundle: URL? = Bundle.main.bundleURL

    /// The menu's entries; the ids stay valid until the next list.
    func list(from source: any AgentPaneBrowserApps) -> [[String: String]] {
        apps = [:]
        var entries: [[String: String]] = []
        var seen = Set<String>()
        for app in source.applications().prefix(16) {
            let standard = app.standardizedFileURL
            guard standard != ownBundle?.standardizedFileURL else { continue }
            let bundleID = Bundle(url: standard)?.bundleIdentifier ?? standard.path
            guard seen.insert(bundleID).inserted else { continue }
            let id = UUID().uuidString
            apps[id] = standard
            var entry = ["id": id, "name": source.displayName(of: standard)]
            if let png = source.iconPNG(of: standard) { entry["icon"] = "data:image/png;base64," + png.base64EncodedString() }
            entries.append(entry)
        }
        return entries
    }

    func app(_ id: String) -> URL? { apps[id] }
}
