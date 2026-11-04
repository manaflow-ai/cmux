// The view shell (README.md): one real window per `--size`, each showing the webviews mock app.
// Thin on purpose: the window, its web view and the URL. The fixture, scripts and every other
// condition axis are URL keys the web side reads (webviews/src/gallery/app/axes.ts).
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct Options {
    var base = URL(string: "http://127.0.0.1:4210/gallery/app.html")!
    var dist: URL?
    var sizes: [CGSize] = []
    var query: [(String, String)] = []
    var capture: URL?
    var quitAfterCapture = false
    /// Seconds a window may take to report ready before `--capture` gives up on it.
    var readyTimeout: Double = 60
    /// The live code folder (LiveCode.swift): patch dylibs dropped here apply to the running shell.
    var live: URL?
    /// Offscreen badge pictures per live code generation (LiveCode.render).
    var liveRender: URL?
    /// No windows: the live code loop alone, for a host with no screen.
    var headless = false

    static let usage = """
    usage: cmux-view-shell [--url URL | --dist DIR] [--size WxH]... [--capture DIR [--quit]] [--KEY VALUE]...
      --url URL      the mock app page (default: the gallery dev server, http://127.0.0.1:4210/gallery/app.html)
      --dist DIR     a built gallery folder (bun run gallery:build) instead of a server
      --size WxH     a window of that size in points; repeat for several windows (default 1280x800)
      --capture DIR  save each window as DIR/<W>x<H>.png once its panes are ready; --quit then exits
                     (exit 1 when a window is not ready within --ready-timeout seconds, default 60)
      --live DIR     apply live code patches dropped into DIR (inject.sh; a Debug build)
      --live-render DIR  also draw the badge offscreen to DIR/generation-N.png after each patch
      --headless     no windows (with --live: the live code loop alone, for a host with no screen)
      --KEY VALUE    any mock app axis, e.g. --fixture app.window/new-tab --density compact --script streaming
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ShellError.usage("\(flag) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--url":
                guard let url = URL(string: try value(flag)) else { throw ShellError.usage("--url is not a URL") }
                options.base = url
            case "--dist":
                options.dist = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath, isDirectory: true)
            case "--size":
                let parts = try value(flag).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 >= 320 && $0 <= 5120 }) else {
                    throw ShellError.usage("--size takes WxH, each 320 to 5120")
                }
                options.sizes.append(CGSize(width: parts[0], height: parts[1]))
            case "--capture":
                options.capture = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath, isDirectory: true)
            case "--ready-timeout":
                guard let seconds = Double(try value(flag)), seconds > 0 else { throw ShellError.usage("--ready-timeout takes seconds") }
                options.readyTimeout = seconds
            case "--live":
                options.live = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath, isDirectory: true)
            case "--live-render":
                options.liveRender = URL(fileURLWithPath: (try value(flag) as NSString).expandingTildeInPath, isDirectory: true)
            case "--headless":
                options.headless = true
            case "--quit":
                options.quitAfterCapture = true
            case "-h", "--help":
                throw ShellError.usage(nil)
            default:
                guard flag.hasPrefix("--"), flag.count > 2 else { throw ShellError.usage("unknown argument \(flag)") }
                options.query.append((String(flag.dropFirst(2)), try value(flag)))
            }
            index += 1
        }
        if options.sizes.isEmpty { options.sizes = [CGSize(width: 1280, height: 800)] }
        return options
    }
}

enum ShellError: Error {
    case usage(String?)
}

/// The person's look from cmux-next.json (`appearance.theme`, `appearance.accent`), as URL keys.
/// A light/dark pair takes the side the system shows. Keys the command line sets win.
func configQuery(appearanceIsDark: Bool) -> [(String, String)] {
    let path = ProcessInfo.processInfo.environment["CMUX_NEXT_CONFIG_FILE"]
        ?? ("~/.config/cmux/cmux-next.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
          let appearance = root["appearance"] as? [String: Any] else { return [] }
    var query: [(String, String)] = []
    if let theme = appearance["theme"] as? String, !theme.isEmpty {
        var named = theme
        if theme.contains(":") {
            let sides = Dictionary(theme.split(separator: ",").compactMap { side -> (String, String)? in
                let pair = side.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            }, uniquingKeysWith: { _, last in last })
            named = sides[appearanceIsDark ? "dark" : "light"] ?? sides.values.first ?? theme
        }
        query.append(("theme", named))
    }
    if let accent = appearance["accent"] as? String, !accent.isEmpty { query.append(("accent", accent)) }
    return query
}

/// Serves a built gallery folder as `cmux-preview://app/...`, so its module scripts load (a
/// `file:` page cannot import modules).
@MainActor
final class FolderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-preview"
    let root: URL

    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let relative = url.path.isEmpty || url.path == "/" ? "app.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = FileManager.default.contents(atPath: file.path) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// One preview window: the system window, its vibrancy, and the page.
@MainActor
final class PreviewWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    let size: CGSize
    let started = Date()
    let onReady: (PreviewWindow, Double) -> Void

    init(size: CGSize, url: URL, scheme: FolderSchemeHandler?, origin: CGPoint, badge: String, onReady: @escaping (PreviewWindow, Double) -> Void) {
        self.size = size
        self.onReady = onReady
        window = NSWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "\(Int(size.width))×\(Int(size.height))"
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        if let scheme { configuration.setURLSchemeHandler(scheme, forURLScheme: FolderSchemeHandler.scheme) }
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "cmuxPreview")
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        let glass = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.autoresizingMask = [.width, .height]
        glass.addSubview(webView)
        window.contentView = glass
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = NSHostingView(rootView: BadgeRoot(text: badge))
        window.addTitlebarAccessoryViewController(accessory)
        webView.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["status"] as? String == "ready" else { return }
        onReady(self, Date().timeIntervalSince(started) * 1000)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        FileHandle.standardError.write(Data("view-shell: \(window.title): \(error.localizedDescription)\n".utf8))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        FileHandle.standardError.write(Data("view-shell: \(window.title) did not load (is `bun run gallery:dev` running?): \(error.localizedDescription)\n".utf8))
    }

    func capture(to folder: URL) async throws -> URL {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw URLError(.cannotCreateFile)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(Int(size.width))x\(Int(size.height)).png")
        try png.write(to: file)
        return file
    }
}

@MainActor
final class ShellDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    var windows: [PreviewWindow] = []
    /// Windows already captured: a page reload reports ready again, and counts once.
    var captured = Set<ObjectIdentifier>()

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let given = Set(options.query.map(\.0))
        let query = configQuery(appearanceIsDark: dark).filter { !given.contains($0.0) } + options.query + [("chrome", "native")]
        let scheme = options.dist.map(FolderSchemeHandler.init(root:))
        let base = scheme != nil ? URL(string: "\(FolderSchemeHandler.scheme)://app/app.html")! : options.base
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
        let url = components.url!
        print("view-shell: \(url.absoluteString)")
        let state = options.query.filter { ["fixture", "density", "script"].contains($0.0) }.map(\.1).joined(separator: " · ")
        if let live = options.live {
            if let folder = options.liveRender { LiveCode.shared.render = (folder, state.isEmpty ? "live code" : state) }
            LiveCode.shared.watch(live)
            LiveCode.shared.drawn()
        }
        var origin = CGPoint(x: 40, y: 60)
        for size in options.sizes {
            windows.append(PreviewWindow(
                size: size, url: url, scheme: scheme, origin: origin,
                badge: ["\(Int(size.width))×\(Int(size.height))", state].filter { !$0.isEmpty }.joined(separator: " · ")
            ) { [weak self] window, ms in
                self?.ready(window, ms: ms)
            })
            origin.x += 40
            origin.y += 40
        }
        NSApp.activate()
        if options.capture != nil, options.quitAfterCapture {
            let timeout = options.readyTimeout
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.captured.count < self.windows.count else { return }
                FileHandle.standardError.write(Data("view-shell: \(self.windows.count - self.captured.count) window(s) not ready after \(Int(timeout)) s\n".utf8))
                exit(1)
            }
        }
    }

    func ready(_ window: PreviewWindow, ms: Double) {
        print("view-shell: \(window.window.title) ready_ms=\(Int(ms.rounded()))")
        guard let folder = options.capture, !captured.contains(ObjectIdentifier(window)) else { return }
        captured.insert(ObjectIdentifier(window))
        Task { @MainActor in
            do {
                print("view-shell: captured \(try await window.capture(to: folder).path)")
            } catch {
                FileHandle.standardError.write(Data("view-shell: capture failed: \(error)\n".utf8))
            }
            if options.quitAfterCapture, captured.count == windows.count { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// One line at a time, so a harness reading the log sees each event as it happens.
setvbuf(stdout, nil, _IOLBF, 0)
let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch ShellError.usage(let message) {
    if let message { FileHandle.standardError.write(Data("cmux-view-shell: \(message)\n".utf8)) }
    print(Options.usage)
    exit(message == nil ? 0 : 64)
} catch {
    exit(64)
}
if options.headless {
    // No window server needed: the live code loop and its offscreen pictures on the main queue.
    guard let live = options.live else {
        FileHandle.standardError.write(Data("cmux-view-shell: --headless needs --live DIR\n".utf8))
        exit(64)
    }
    if let folder = options.liveRender { LiveCode.shared.render = (folder, "live code") }
    LiveCode.shared.watch(live)
    LiveCode.shared.drawn()
    // The main run loop, not dispatchMain(): dispatchMain parks the main thread and drains the main
    // queue on a worker, and SwiftUI's renderer waits for the real main thread (a deadlock on the
    // first patch). The run loop drains the main queue on the main thread.
    while true { RunLoop.main.run() }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ShellDelegate(options: options)
app.delegate = delegate
app.run()
