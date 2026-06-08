#if canImport(WebKit)
import Foundation
@preconcurrency import WebKit

/// The custom URL scheme the diff viewer host serves everything under. A
/// dedicated app-private scheme (not `http`/`https`) means the bundle, its
/// worker, and the patch share one origin with no network or ATS exposure, and
/// the React app's relative URLs resolve against it unchanged.
let diffViewerScheme = "cmux-diff"

/// Origin host for the diff viewer custom scheme. The full page URL is
/// `cmux-diff://viewer/`.
let diffViewerHost = "viewer"

/// Serves the diff-viewer page over the `cmux-diff://` scheme: the generated
/// host HTML at the origin root, the patch text at `diff.patch`, and every
/// bundled asset (the React entry, its chunks, and the vendored `@pierre/diffs`
/// worker assets) from the package's `DiffViewerBundle` resources.
///
/// This one handler is the whole content-serving seam: the dynamic page/patch
/// come from its injected `html`/`patch`, the static files from the package
/// bundle. If the iOS WebKit module-worker-over-custom-scheme path ever proves
/// unworkable, swapping this for a loopback HTTP server only has to reproduce
/// this small "origin root → HTML, `diff.patch` → patch, everything else →
/// bundle file" contract.
///
/// `WKURLSchemeHandler` callbacks arrive on the main thread; the handler is
/// `@MainActor`-isolated and never blocks (the largest file, the ~10MB diff
/// vendor chunk, is read with `Data(contentsOf:)` once and handed to WebKit).
@MainActor
final class DiffViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String
    private let patchData: Data
    private let bundleAssetsRoot: URL?
    /// Tracks tasks WebKit has told us to stop so a late completion is dropped.
    private var stoppedTasks: Set<ObjectIdentifier> = []

    /// - Parameters:
    ///   - html: The generated host HTML served at the origin root.
    ///   - patch: The unified diff patch text served at `diff.patch`.
    init(html: String, patch: String) {
        self.html = html
        self.patchData = Data(patch.utf8)
        // The `.copy("DiffViewerBundle")` resource lands as a `DiffViewerBundle`
        // directory inside the module bundle. Asset requests are resolved
        // relative to it.
        self.bundleAssetsRoot = Bundle.module.url(
            forResource: "DiffViewerBundle",
            withExtension: nil
        )
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, taskID: taskID, status: 400)
            return
        }

        let relativePath = Self.normalizedRelativePath(for: url)

        // Origin root (or an explicit index) serves the host HTML.
        if relativePath.isEmpty || relativePath == "index.html" {
            respond(urlSchemeTask, taskID: taskID, data: Data(html.utf8), mimeType: "text/html", url: url)
            return
        }

        // The patch the React bundle fetches as its `patchURL`.
        if relativePath == DiffViewerHostHTML.patchPath {
            respond(urlSchemeTask, taskID: taskID, data: patchData, mimeType: "text/x-diff", url: url)
            return
        }

        // Everything else is a static bundle asset under `assets/...`.
        guard let assetURL = resolvedAssetURL(for: relativePath) else {
            fail(urlSchemeTask, taskID: taskID, status: 404)
            return
        }
        guard let data = try? Data(contentsOf: assetURL) else {
            fail(urlSchemeTask, taskID: taskID, status: 404)
            return
        }
        respond(
            urlSchemeTask,
            taskID: taskID,
            data: data,
            mimeType: Self.mimeType(forPathExtension: assetURL.pathExtension),
            url: url
        )
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: - Asset resolution

    /// Map a request path to a file inside the bundled assets, rejecting any
    /// path that would escape the bundle root (defense-in-depth path traversal
    /// guard, even though the scheme is app-private).
    private func resolvedAssetURL(for relativePath: String) -> URL? {
        guard let root = bundleAssetsRoot else { return nil }
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path == standardizedRoot.path
            || candidate.path.hasPrefix(standardizedRoot.path + "/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    /// The request path relative to the origin root, with any leading slash and
    /// query/fragment removed.
    static func normalizedRelativePath(for url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        return path
    }

    /// MIME type for an asset extension. Module scripts MUST be served as a
    /// JavaScript type or WebKit refuses to evaluate them, so `.mjs`/`.js` map to
    /// `text/javascript`.
    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mjs", "js":
            return "text/javascript"
        case "html":
            return "text/html"
        case "css":
            return "text/css"
        case "json", "map":
            return "application/json"
        case "wasm":
            return "application/wasm"
        case "svg":
            return "image/svg+xml"
        case "patch", "diff":
            return "text/x-diff"
        default:
            return "application/octet-stream"
        }
    }

    // MARK: - Responding

    private func respond(
        _ task: any WKURLSchemeTask,
        taskID: ObjectIdentifier,
        data: Data,
        mimeType: String,
        url: URL
    ) {
        guard !stoppedTasks.contains(taskID) else {
            stoppedTasks.remove(taskID)
            return
        }
        var headers = [
            "Content-Type": mimeType,
            "Content-Length": String(data.count),
            // The page and its assets are generated/bundled per presentation; no
            // cross-origin access is possible on an app-private scheme.
            "Cache-Control": "no-store",
        ]
        // Module workers and ES module imports need a permissive same-origin
        // policy; the app-private scheme is the only origin in play.
        headers["Access-Control-Allow-Origin"] = "*"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? HTTPURLResponse()
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, taskID: ObjectIdentifier, status: Int) {
        guard !stoppedTasks.contains(taskID) else {
            stoppedTasks.remove(taskID)
            return
        }
        let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: "\(diffViewerScheme)://\(diffViewerHost)/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) ?? HTTPURLResponse()
        task.didReceive(response)
        task.didFinish()
    }
}
#endif
