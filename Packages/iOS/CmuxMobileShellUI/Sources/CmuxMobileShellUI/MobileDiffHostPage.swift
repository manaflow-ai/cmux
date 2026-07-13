import Foundation

/// Generates the minimal HTML shell consumed by the bundled cmux diff app.
struct MobileDiffHostPage: Sendable {
    enum Layout: String, Sendable {
        case unified
        case split
    }

    let origin: URL
    let layout: Layout
    let title: String
    let labels: [String: String]

    func htmlData() throws -> Data {
        let base = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config: [String: Any] = [
            "payload": [
                "mobileHost": true,
                "patchURL": "\(base)/patch",
                "layout": layout.rawValue,
                "layoutSource": "explicit",
                "appearance": MobileDiffAppearance().jsonObject,
                "labels": labels,
                "title": title,
            ],
            "assets": [
                "diffsModuleURL": "\(base)/diff-viewer/diffs.mjs",
                "treesModuleURL": "\(base)/diff-viewer/trees.mjs",
                "workerPoolModuleURL": "\(base)/diff-viewer/worker-pool/worker-pool.mjs",
                "workerModuleURL": "\(base)/diff-viewer/worker-pool/worker-portable.js",
            ],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard var json = String(data: jsonData, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        json = json.replacingOccurrences(of: "</", with: "<\\/")
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let html = """
        <!doctype html>
        <html lang="\(Locale.current.language.languageCode?.identifier ?? "en")">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(escapedTitle)</title>
          <style>
            :root { color-scheme: light dark; background: transparent; }
            html, body, #root { min-height: 100%; }
            html, body { margin: 0; background: transparent; }
          </style>
        </head>
        <body>
          <script type="application/json" id="cmux-diff-viewer-config">\(json)</script>
          <div id="root"></div>
          <script type="module" src="\(base)/webviews-app/main.mjs"></script>
        </body>
        </html>
        """
        return Data(html.utf8)
    }
}
