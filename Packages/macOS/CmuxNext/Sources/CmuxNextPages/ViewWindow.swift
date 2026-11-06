public import AppKit
import CmuxNextCompat
import CmuxNextSettings
public import Foundation
import WebKit

/// The view window (`debug.viewWindow`, Debug menu > Open View Window, DEV and NIGHTLY): the app's UI as
/// your checkout has it, in a window of the running app, so seeing a UI change needs no separate DEV build
/// or shell build. Leo, 2026-11-04: "shouldn't the nightly itself or whatever stable app be able to simply
/// do this? Like the view if you wanna separate it out or if you just wanna update your thing on the fly".
///
/// Its content is the webviews mock app (`webviews/src/gallery/mock-app.html` with `chrome=native`, as in
/// `Prototypes/ViewShell`) from the gallery dev server (`bun run gallery:dev`), so a saved web file hot
/// reloads in it while the app's own windows keep the bundled pages. Updating the app's own windows on the
/// fly is `web-dev.json` (``WebDevOverride``). Each `open` is a new window, offset from the last, so
/// several sizes can sit side by side.
@MainActor public final class ViewWindow: NSObject, NSWindowDelegate {
    /// The gallery dev server's port (`bun run gallery:dev`).
    public nonisolated static let defaultPort = 4210

    private var windows: [NSWindow] = []

    override public init() {}

    /// Opens one view window now; its page loads once the person's look is read off the main thread.
    /// - Parameter arguments: The action's arguments: `port` (the gallery dev server's loopback port,
    ///   default ``defaultPort``), `width` and `height` (points, default 1280×800), and every other key a
    ///   mock app key (`fixture`, `density`, `script`, ...) that wins over the person's look.
    public func open(arguments: [String: String]) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (port, size, query) = Self.parse(arguments)
        let (window, webView) = makeWindow(size: size)
        window.delegate = self
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        let file = CmuxConfigFile.defaultURL()
        Task { [weak webView] in
            let look = await Self.readLook(file, dark: dark)
            guard let url = Self.url(port: port, look: look, query: query) else { return }
            webView?.load(URLRequest(url: url))
        }
    }

    public func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }

    private func makeWindow(size: CGSize) -> (NSWindow, WKWebView) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "\(Int(size.width))×\(Int(size.height))"
        window.isReleasedWhenClosed = false
        let glass = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.autoresizingMask = [.width, .height]
        // webview-allow: a Debug window over the gallery dev server's mock app on loopback, with no bridge to the app; not a cmux page
        let webView = WKWebView(frame: glass.bounds, configuration: WKWebViewConfiguration())
        PageWebView.clearBackground(of: webView)
        webView.autoresizingMask = [.width, .height]
        glass.addSubview(webView)
        window.contentView = glass
        if let last = windows.last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 40, y: last.frame.maxY - 40))
        } else {
            window.center()
        }
        return (window, webView)
    }

    // MARK: Pure parts (ViewWindowTests)

    /// The mock app on `127.0.0.1:port`: the person's look, then `query` (which wins over the look), then
    /// `chrome=native`. Always loopback: the window has no bridge to the app, but it is a page in its process.
    nonisolated static func url(port: Int, look: [(String, String)], query: [(String, String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/gallery/mock-app.html"
        let given = Set(query.map(\.0))
        let items = look.filter { !given.contains($0.0) } + query.filter { $0.0 != "chrome" } + [("chrome", "native")]
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }

    /// The mock app keys of the person's look in `cmux-next.json`: `appearance.theme` (a light/dark pair
    /// takes the side the system shows) and `appearance.accent`.
    nonisolated static func lookQuery(config: [String: Any]?, dark: Bool) -> [(String, String)] {
        guard let appearance = config?["appearance"] as? [String: Any] else { return [] }
        var query: [(String, String)] = []
        if let theme = (appearance["theme"] as? String)?.trimmingCharacters(in: .whitespaces), !theme.isEmpty {
            query.append(("theme", side(of: theme, dark: dark)))
        }
        if let accent = appearance["accent"] as? String, !accent.isEmpty { query.append(("accent", accent)) }
        return query
    }

    /// One side of `light:A,dark:B`; a single name is itself.
    nonisolated static func side(of theme: String, dark: Bool) -> String {
        guard theme.contains(":") else { return theme }
        var sides: [String: String] = [:]
        for part in theme.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { sides[pair[0]] = pair[1] }
        }
        return sides[dark ? "dark" : "light"] ?? sides[dark ? "light" : "dark"] ?? theme
    }

    /// The port, the clamped size and the mock app keys (sorted) of the action's arguments.
    nonisolated static func parse(_ arguments: [String: String]) -> (port: Int, size: CGSize, query: [(String, String)]) {
        let port = arguments["port"].flatMap(Int.init).flatMap { (1...65_535).contains($0) ? $0 : nil } ?? defaultPort
        let width = arguments["width"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 1280
        let height = arguments["height"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 800
        let query = arguments.filter { !["port", "width", "height"].contains($0.key) }.map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
        return (port, clamped(CGSize(width: width, height: height)), query)
    }

    /// Each side between 320 and 5120 points, as the view shell takes them.
    nonisolated static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, 320), 5120), height: min(max(size.height, 320), 5120))
    }

    /// ``lookQuery(config:dark:)`` of `file` (`cmux-next.json`, JSON5), read off the main thread.
    @concurrent nonisolated static func readLook(_ file: URL, dark: Bool) async -> [(String, String)] {
        let data = try? Data(blockingContentsOf: file)
        let config = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.json5Allowed]) } as? [String: Any]
        return lookQuery(config: config, dark: dark)
    }
}
