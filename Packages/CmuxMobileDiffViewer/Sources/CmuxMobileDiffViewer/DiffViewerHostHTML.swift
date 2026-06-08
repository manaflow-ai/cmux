import Foundation

/// Builds the host HTML page that boots the diff-viewer React bundle inside a
/// `WKWebView`, mirroring the page the desktop CLI generates in
/// `writeDiffViewerHTML`.
///
/// The page embeds a `cmux-diff-viewer-config` JSON `<script>` (the bundle reads
/// it from `mountDiffSurface`) and loads the app entry module. Every URL the
/// config carries — the `patchURL` and the `assets.*ModuleURL` set — is relative
/// to the single custom-scheme origin the host serves, so the React bundle, its
/// chunks, the vendored `@pierre/diffs` worker, and the patch are all
/// same-origin (the worker can load from the same scheme, and the patch fetch is
/// not cross-origin).
enum DiffViewerHostHTML {
    /// The asset directory names the bundle expects, matching the desktop's
    /// `ensureDiffViewerAssets` layout. The Swift package copies the React bundle
    /// into `DiffViewerBundle/assets/<these names>/`.
    enum AssetDirectory {
        static let app = "cmux-webviews-app"
        static let pierre = "pierre-diffs-1.2.7-trees-1.0.0-beta.4"
    }

    /// Relative URLs (from the host page) for each asset the config references.
    /// Identical to the strings the desktop's `DiffViewerAssets` carries.
    static let appModuleURL = "./assets/\(AssetDirectory.app)/main.mjs"
    static let diffsModuleURL = "./assets/\(AssetDirectory.pierre)/diffs.mjs"
    static let treesModuleURL = "./assets/\(AssetDirectory.pierre)/trees.mjs"
    static let workerPoolModuleURL = "./assets/\(AssetDirectory.pierre)/worker-pool/worker-pool.mjs"
    static let workerModuleURL = "./assets/\(AssetDirectory.pierre)/worker-pool/worker-portable.js"

    /// The relative URL the bundle fetches the patch from. Served by the host's
    /// scheme handler from the RPC-fetched patch text.
    static let patchPath = "diff.patch"

    /// Generate the host HTML for a diff viewer page.
    ///
    /// - Parameters:
    ///   - title: The document title shown while loading.
    ///   - sourceLabel: A short label for the diff source (e.g. "git unstaged").
    ///   - prefersDark: Whether to seed a dark prepaint background so the first
    ///     paint matches the app's terminal theme instead of flashing white.
    /// - Returns: A complete HTML document string.
    static func page(title: String, sourceLabel: String?, prefersDark: Bool) -> String {
        // Minimal config: the bundle's label resolver falls back to built-in
        // English defaults for any missing key (it only asserts in a DEV build,
        // and this is the production bundle), and the appearance resolver applies
        // sensible defaults when `appearance` is absent. P1 ships read-only with
        // no source switcher, so `sourceOptions` is empty.
        var payload: [String: Any] = [
            "patchURL": patchPath,
            "title": title,
            "layout": "unified",
            "layoutSource": "default",
            "sourceOptions": [[String: Any]](),
            "repoOptions": [[String: Any]](),
            "baseOptions": [[String: Any]](),
        ]
        if let sourceLabel, !sourceLabel.isEmpty {
            payload["sourceLabel"] = sourceLabel
        }
        let config: [String: Any] = [
            "payload": payload,
            "assets": [
                "diffsModuleURL": diffsModuleURL,
                "treesModuleURL": treesModuleURL,
                "workerPoolModuleURL": workerPoolModuleURL,
                "workerModuleURL": workerModuleURL,
            ],
        ]
        let configLiteral = jsonScriptLiteral(config)
        let escapedTitle = htmlEscaped(title)
        let background = prefersDark ? "#0d1117" : "#ffffff"
        let foreground = prefersDark ? "#e6edf3" : "#1f2328"
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(escapedTitle)</title>
          <style>
            html, body { margin: 0; padding: 0; height: 100%; background: \(background); color: \(foreground); }
            #root { height: 100%; }
          </style>
        </head>
        <body>
          <script id="cmux-diff-viewer-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="\(htmlEscaped(appModuleURL))"></script>
        </body>
        </html>
        """
    }

    /// Serialize a JSON object for safe embedding inside a `<script>` element.
    /// `</script>` and HTML comment openers are escaped so the JSON cannot break
    /// out of the script context.
    static func jsonScriptLiteral(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Minimal HTML attribute/text escaping for the title and asset URLs.
    static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
