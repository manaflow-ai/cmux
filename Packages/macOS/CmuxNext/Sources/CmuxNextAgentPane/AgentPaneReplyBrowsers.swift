public import AppKit
import CmuxNextCompatAppKit
public import CmuxNextWakeups
import CmuxNextPages
public import Foundation

/// The installed web browsers for a preview card's "Open in" menu (decision D6). The page gets
/// only an opaque id, a name and an icon for each; it sends back `{url, browserId}`, and the host
/// opens only an app from the list it made, only for a validated http(s) URL
/// (``AgentPaneReplyRequest/webURL(_:)``), with `NSWorkspace.openInBackground(_:withApplicationAt:)`: no
/// shell, no `open(1)`, never an app path or name from the page (unlike
/// `LinkMenu.application(named:)`, which takes any name).
@MainActor public protocol AgentPaneBrowserApps: AnyObject {
    /// The apps that open `https` URLs, the default first.
    func applications() -> [URL]
    func displayName(of app: URL) -> String
    /// The app's icon as PNG, about 32 px.
    func iconPNG(of app: URL) -> Data?
    func open(_ url: URL, withApplicationAt app: URL)
}

/// The installed browsers over Launch Services. The list and the icons are answers kept by the app's
/// ``WorkspaceQueries`` (the link menus share the list): asked on the system lane when this is made, so a card reads
/// them kept. A card opened before they land lists what is kept and asks for the rest.
@MainActor public final class AgentPaneWorkspaceBrowsers: AgentPaneBrowserApps {
    private let queries: WorkspaceQueries?
    private let workspace: NSWorkspace

    /// - Parameters:
    ///   - queries: The app's Launch Services answers; nil lists no browser.
    ///   - workspace: Opens the chosen browser, off the main thread.
    public init(queries: WorkspaceQueries?, workspace: NSWorkspace = .shared) {
        self.queries = queries
        self.workspace = workspace
        warm()
    }

    /// Asks for the browser list and, when it lands, their icons.
    private func warm() {
        queries?.value(Self.list, priority: .bestEffort) { [weak self] apps in
            self?.queries?.prefetch(apps.prefix(16).map { Self.iconPNGQuery($0) }, priority: .bestEffort)
        }
    }

    public func applications() -> [URL] {
        guard let queries else { return [] }
        if let kept = queries.cached(Self.list) { return kept }
        warm()
        return []
    }

    public func displayName(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    public func iconPNG(of app: URL) -> Data? {
        guard let queries else { return nil }
        let query = Self.iconPNGQuery(app)
        if let kept = queries.cached(query) { return kept }
        queries.prefetch([query], priority: .userVisible)
        return nil
    }

    /// The apps that open https links, the default first (the link menus' list).
    nonisolated static var list: WorkspaceQuery<[URL]> { LinkMenu.browsers(scheme: "http", own: Bundle.main.bundleURL) }

    /// `app`'s icon as a PNG of about 32 px, drawn on the system lane into a bitmap of its own.
    nonisolated static func iconPNGQuery(_ app: URL) -> WorkspaceQuery<Data?> {
        WorkspaceQuery(id: "agentPane.browserIconPNG." + app.path, refreshes: false) { system in
            let icon = system.fileIcon(atPath: app.path)
            let side = 32
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            context.flushGraphics()
            return rep.representation(using: .png, properties: [:])
        }
    }

    public func open(_ url: URL, withApplicationAt app: URL) {
        workspace.openInBackground([url], withApplicationAt: app)
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
