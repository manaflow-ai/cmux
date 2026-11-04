import AppKit
import WebKit

/// What scripts/cmux-next/gallery-window.py resolved: the stages to open and the backdrop the
/// person's app draws behind them. The launcher owns every decision; this host only draws it.
struct GallerySpec: Decodable {
    struct Stage: Decodable {
        var title: String
        var url: String
        var width: Double
        var height: Double
    }

    struct Backdrop: Decodable {
        /// `opaque` (the page paints its own background), `art` (the picture at `image`, aspect
        /// filled), `desktop` (the screen's desktop picture) or `glass` (the desktop through a
        /// behind-window material).
        var kind: String
        var image: String?
    }

    var stages: [Stage]
    var backdrop: Backdrop
    /// `dark` or `light`: the window appearance the resolved theme shows.
    var appearance: String
    /// Seconds a stage rests after its play before it replays; 0 shows it once.
    var loopSeconds: Double
}

enum SpecError: Error, CustomStringConvertible {
    case usage

    var description: String { "usage: cmux-gallery-window --spec PATH (scripts/cmux-next/gallery-window.py writes it)" }
}

func readSpec() throws -> GallerySpec {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--spec"), index + 1 < arguments.count else { throw SpecError.usage }
    // concurrency-allow: launch-time read of the launcher's small spec file, before any window exists.
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
    return try JSONDecoder().decode(GallerySpec.self, from: data)
}

/// The backdrop behind a clear web view, as WindowBackdrop layers the app's window: the picture
/// (or the desktop's glass) under the page, and the page paints the theme tint over it.
@MainActor
final class BackdropView: NSView {
    init(_ backdrop: GallerySpec.Backdrop, screen: NSScreen?) {
        super.init(frame: .zero)
        wantsLayer = true
        switch backdrop.kind {
        case "glass":
            let material = NSVisualEffectView()
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            material.state = .active
            material.autoresizingMask = [.width, .height]
            addSubview(material)
        case "art", "desktop":
            let url = backdrop.kind == "desktop"
                ? (screen ?? NSScreen.main).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
                : backdrop.image.map { URL(fileURLWithPath: $0) }
            // NSImage decodes the bundled AVIF art on macOS 13 and later.
            if let url, let image = NSImage(contentsOf: url) {
                layer?.contents = image
                layer?.contentsGravity = .resizeAspectFill
                layer?.masksToBounds = true
            }
        default:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// One stage in its own window. A stage replays itself: the frame posts `cmux-gallery-stage`
/// ready after its play steps, and the host reloads it after `loopSeconds`.
@MainActor
final class StageWindowController: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    let window: NSWindow
    private let webView: WKWebView
    private let url: URL
    private let loopSeconds: Double
    private var replay: Task<Void, Never>?
    private let onClose: (StageWindowController) -> Void

    init(stage: GallerySpec.Stage, spec: GallerySpec, origin: NSPoint, onClose: @escaping (StageWindowController) -> Void) {
        url = URL(string: stage.url) ?? URL(fileURLWithPath: "/")
        loopSeconds = spec.loopSeconds
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: stage.width, height: stage.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        // The frame's ready message goes to its parent, which is the page itself at the top level.
        controller.addUserScript(WKUserScript(
            source: """
            addEventListener("message", (event) => {
              if (event.data && event.data.type === "cmux-gallery-stage" && event.data.status === "ready")
                webkit.messageHandlers.galleryWindow.postMessage("ready");
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(self, name: "galleryWindow")

        window.title = stage.title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: spec.appearance == "light" ? .aqua : .darkAqua)
        window.delegate = self
        let content = NSView()
        if spec.backdrop.kind != "opaque" {
            window.isOpaque = false
            // Not clear: alpha 0.001 keeps the window's shadow and hit testing (WindowBackdrop).
            window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            let backdrop = BackdropView(spec.backdrop, screen: window.screen)
            backdrop.autoresizingMask = [.width, .height]
            content.addSubview(backdrop)
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        window.contentView = content
        for view in content.subviews { view.frame = content.bounds }
        webView.load(URLRequest(url: url))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard loopSeconds > 0, replay == nil else { return }
        let seconds = loopSeconds
        // Stops when the window closes (windowWillClose cancels it); one pending replay at a time.
        replay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.replay = nil
            self.webView.reload()
        }
    }

    func reload() { webView.reload() }

    func windowWillClose(_ notification: Notification) {
        replay?.cancel()
        replay = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "galleryWindow")
        onClose(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spec: GallerySpec
    private var controllers: [StageWindowController] = []

    init(spec: GallerySpec) { self.spec = spec }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        // Side by side from the top left of the main screen, wrapping to a new row when full.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        var x = visible.minX + 24
        var rowTop = visible.maxY - 24
        var rowHeight = 0.0
        for stage in spec.stages {
            if x + stage.width > visible.maxX, x > visible.minX + 24 {
                x = visible.minX + 24
                rowTop -= rowHeight + 24
                rowHeight = 0
            }
            let origin = NSPoint(x: x, y: max(visible.minY, rowTop - stage.height))
            let controller = StageWindowController(stage: stage, spec: spec, origin: origin) { [weak self] closed in
                self?.controllers.removeAll { $0 === closed }
            }
            controllers.append(controller)
            controller.window.makeKeyAndOrderFront(nil)
            x += stage.width + 24
            rowHeight = max(rowHeight, stage.height)
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func reloadAll(_ sender: Any?) { controllers.forEach { $0.reload() } }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Reload All", action: #selector(reloadAll(_:)), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let spec: GallerySpec
    do {
        spec = try readSpec()
    } catch {
        FileHandle.standardError.write(Data("cmux-gallery-window: \(error)\n".utf8))
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(spec: spec)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
