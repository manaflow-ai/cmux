import AppKit
import CmuxNextActions
import CmuxNextBrowser
@testable import CmuxNextApp
import CmuxNextFiles
import CmuxNextFilesUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import WebKit
import UniformTypeIdentifiers

/// u9489 (Oct 21): "I want to be able to right-click and open it as text instead of as the HTML
/// page. I want to open it in Monaco editor instead." A page cmux renders (HTML, SVG, Markdown)
/// gets Open as Text wherever its Open is: the shared file menu (Home attachments and file
/// links), the Files pane and the Files sidebar. Every row runs one path: ``LinkOpener`` with
/// `asText`, which ``FilePageOpener`` routes to the code editor page.
@MainActor @Suite(.serialized)
struct FileOpenAsTextTests {
    struct NoApps: FileAppsProviding {
        func openWithList(forFileNamed name: String, isDirectory: Bool) async -> OpenWithList { OpenWithList(defaultApp: nil, apps: []) }
        func open(_ files: [URL], withApplicationAt app: URL) async -> Bool { false }
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/site/\(name)") }

    // MARK: The one route

    @Test(arguments: [
        ("index.html", FilePageOpener.Route.renderedPage, FilePageOpener.Route.editor),
        ("logo.svg", .renderedPage, .editor),
        ("README.md", .markdown, .editor),
        ("main.swift", .editor, .editor),
        ("shot.png", .preview, .preview),
    ])
    func openAsTextRoutesARenderedPageToTheCodeEditor(name: String, open: FilePageOpener.Route, asText: FilePageOpener.Route) {
        #expect(FilePageOpener.route(for: Self.url(name), userChose: true) == open)
        #expect(FilePageOpener.route(for: Self.url(name), userChose: true, asText: true) == asText)
    }

    @Test(arguments: ["sidebar-clean-cmux.png", "wide.jpg", "poster.webp", "document.pdf"])
    func localImageAndPDFPreviewsUseTheScopedWebKitReader(name: String) {
        #expect(FilePageOpener.tabEngine(for: Self.url(name)) == BrowserEngineTag.webkit.rawValue)
    }

    @Test func theScopedWebKitReaderDisplaysALargePNG() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-image-viewer-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sidebar-clean-cmux.png")
        try Self.largeVisiblePNG.write(to: file)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = webView
        let navigation = NavigationCompletion()
        webView.navigationDelegate = navigation
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        try await navigation.wait()
        let visible = try await webView.evaluateJavaScript(
            "document.images.length === 1 && document.images[0].naturalWidth > 0 && document.images[0].naturalHeight > 0"
        ) as? Bool
        #expect(visible == true)
    }

    private static let largeVisiblePNG: Data = {
        let width = 3708, height = 2468
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }()

    @MainActor final class NavigationCompletion: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    // MARK: The shared file menu (Home attachments and file links, the Files pane)

    private func titles(_ rows: [NSMenuItem]) -> [String] { rows.filter { !$0.isSeparatorItem }.map(\.title) }

    @Test func theFileMenuOffersOpenAsTextRightAfterOpenForARenderedPage() throws {
        _ = NSApplication.shared
        var opened: [URL] = []
        let menu = FileActionsMenu(apps: NoApps(), actions: .init(openInCmux: { _ in }, revealInFiles: { _ in },
                                                                  openAsText: { opened.append($0) }))
        let file = Self.url("index.html")
        let rows = menu.items(forFileNamed: "index.html") { file }
        let shown = titles(rows)
        let text = try #require(shown.firstIndex(of: FileActionsMenu.openAsTextTitle), "no Open as Text in \(shown)")
        #expect(text == 1, "Open as Text is not right after Open in Right Pane: \(shown)")
        for name in ["notes.txt", "shot.png", "main.swift"] {
            #expect(!titles(menu.items(forFileNamed: name) { file }).contains(FileActionsMenu.openAsTextTitle), "\(name) offers Open as Text")
        }
        #expect(menu.openAsTextItem(forFileNamed: "site", isDirectory: true) { file } == nil)
    }

    @Test func choosingOpenAsTextRunsTheHostsOpenWithTheFile() async throws {
        _ = NSApplication.shared
        var opened: [URL] = []
        let menu = FileActionsMenu(apps: NoApps(), actions: .init(openInCmux: { _ in Issue.record("Open in Right Pane ran") },
                                                                  revealInFiles: { _ in }, openAsText: { opened.append($0) }))
        let file = Self.url("logo.svg")
        let row = try #require(menu.openAsTextItem(forFileNamed: "logo.svg") { file })
        let action = try #require(row.action)
        NSApp.sendAction(action, to: row.target, from: row)
        for _ in 0..<200 where opened.isEmpty { await Task.yield() }
        #expect(opened == [file])
    }

    @Test func withoutAHostOpenThereIsNoOpenAsText() {
        let menu = FileActionsMenu(apps: NoApps(), actions: .init(openInCmux: { _ in }, revealInFiles: { _ in }))
        #expect(menu.openAsTextItem(forFileNamed: "index.html") { nil } == nil)
    }

    // MARK: The Files sidebar (the registry's fileExplorerRow menu)

    @MainActor final class TextRecorder: FileExplorerEffects {
        private(set) var openedAsText: [URL] = []
        func openInCmux(_ file: URL, at position: FileLineLocation?) -> Bool { true }
        func openAsText(_ file: URL) -> Bool { openedAsText.append(file); return true }
        func openInDefaultApp(_ item: URL) {}
        func revealInFinder(_ item: URL) {}
        func copy(_ text: String) {}
        func open(_ item: URL, withApp app: String) async throws {}
    }

    @Test func theFilesSidebarRowMenuOffersOpenAsTextOnlyForARenderedPage() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let root = try FileExplorerTests.folder()
        try Data("<p>x</p>".utf8).write(to: root.appendingPathComponent("index.html"))
        let model = await FileExplorerTests.model(root)
        let effects = TextRecorder()
        FileExplorerHandlers.bind(into: services.registry, explorer: { _ in FileExplorerRunTarget(model: model) }, effects: effects)
        let section = FileExplorerSectionView(model: model, rootFolder: { nil }, perform: { _ in },
                                              rowMenu: { services.fileExplorers.rowMenu(hasSelection: $0) })
        func ids(_ menu: NSMenu) -> [String] { menu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue } }

        let page = try #require(model.rows.first { $0.name == "index.html" }).url
        model.selection = page
        let menu = try #require(section.table.contextMenu?())
        let shown = ids(menu)
        let open = try #require(shown.firstIndex(of: "fileExplorerOpenInCmux"))
        #expect(shown.firstIndex(of: "fileExplorerOpenAsText") == open + 1, "Open as Text is not right after Open in cmux: \(shown)")
        let row = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "fileExplorerOpenAsText" })
        menu.update()
        let action = try #require(row.action)
        let work = services.registry.capturingWork { _ = NSApp.sendAction(action, to: row.target, from: row) }
        for task in work { #expect(await task.value == nil) }
        #expect(effects.openedAsText == [page])

        model.selection = try #require(model.rows.first { $0.name == "b.txt" }).url
        #expect(!ids(try #require(section.table.contextMenu?())).contains("fileExplorerOpenAsText"), "a text file offers Open as Text")
    }
}
