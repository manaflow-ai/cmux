import AppKit
import CryptoKit
import Foundation

/// Builds the in-memory Monaco editor page the markdown panel's edit mode
/// loads through ``MarkdownEditorSchemeHandler``.
///
/// The page is the same bundled `editor` webviews surface `cmux edit` opens in
/// a browser split (same `main.mjs`, chunks, and Monarch grammars); only the
/// hosting differs. `cmux edit` stages a page into the uid-owned diff-viewer
/// serving directory and mints a save capability through a token sidecar
/// because the CLI is a separate process. The markdown panel generates the
/// page in-process from state it already owns, so no files, tokens, or
/// sidecars are written; the save bridge is the panel's own message handler.
enum MarkdownEditorPage {
    /// Renders the editor page HTML with the surface's JSON config inlined.
    /// Mirrors the shape `cmux edit` writes (`writeEditorHTML`), with the
    /// module script resolved relative to the custom-scheme origin root.
    static func html(
        filePath: String,
        content: String,
        readOnly: Bool,
        contentSha256: String,
        initialDirty: Bool,
        wordWrap: Bool,
        appearance: PanelAppearance
    ) throws -> String {
        let title = (filePath as NSString).lastPathComponent
        let payload: [String: Any] = [
            "filePath": filePath,
            "content": content,
            "title": title,
            "appearance": appearanceJSON(appearance),
            "readOnly": readOnly,
            "contentSha256": contentSha256,
            // True when `content` already diverges from disk (the page is
            // being regenerated from an unsaved buffer, e.g. on a theme
            // change or web-process recovery): the page must keep treating
            // the buffer as dirty until it saves or adopts disk content.
            "initialDirty": initialDirty,
            "labels": labels,
            "wordWrap": wordWrap,
            // The page mirrors dirty state plus the live buffer back to the
            // panel so preview rendering and global search track unsaved
            // edits the way the previous NSTextView editor did.
            "mirrorContent": true
        ]
        let configLiteral = try jsonScriptLiteral(["payload": payload])
        let htmlLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        return """
        <!doctype html>
        <html lang="\(htmlEscaped(htmlLanguage))" data-cmux-webview-kind="editor">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscaped(title))</title>
        </head>
        <body data-cmux-webview-kind="editor">
          <script id="cmux-editor-config" type="application/json">\(configLiteral)</script>
          <div id="root"></div>
          <script type="module" src="./main.mjs"></script>
        </body>
        </html>
        """
    }

    /// The `DiffViewerAppearance` payload the editor surface consumes
    /// (`resolveDiffViewerAppearance`). Both theme slots carry the same
    /// panel-derived colors: the host forces the webview's `NSAppearance` to
    /// match the panel theme, so whichever slot `prefers-color-scheme`
    /// selects renders the panel's colors.
    private static func appearanceJSON(_ appearance: PanelAppearance) -> [String: Any] {
        let config = GhosttyConfig.load()
        let theme: [String: Any] = [
            "background": appearance.backgroundColor.markdownOpaqueSRGB.hexString(),
            "foreground": appearance.foregroundColor.markdownOpaqueSRGB.hexString(),
            "selectionBackground": config.selectionBackground.markdownOpaqueSRGB.hexString(),
            "selectionForeground": config.selectionForeground.markdownOpaqueSRGB.hexString(),
            "type": appearance.backgroundColor.markdownOpaqueSRGB.isLightColor ? "light" : "dark"
        ]
        return [
            "fontFamily": config.fontFamily,
            "fontSize": Double(config.fontSize),
            "themes": ["dark": theme, "light": theme]
        ]
    }

    /// Localized editor-surface labels. Same keys `cmux edit` injects; the
    /// catalog entries already exist for every supported locale.
    private static var labels: [String: String] {
        [
            "conflictChanged": String(localized: "editor.conflict.changed", defaultValue: "The file changed on disk after it was opened."),
            "conflictMissing": String(localized: "editor.conflict.missing", defaultValue: "The file no longer exists on disk."),
            "dismiss": String(localized: "editor.conflict.dismiss", defaultValue: "Dismiss"),
            "modified": String(localized: "editor.status.modified", defaultValue: "Modified"),
            "overwrite": String(localized: "editor.conflict.overwrite", defaultValue: "Overwrite"),
            "readOnly": String(localized: "editor.status.readOnly", defaultValue: "Read-only"),
            "saved": String(localized: "editor.status.saved", defaultValue: "Saved"),
            "saveFailed": String(localized: "editor.error.saveFailed", defaultValue: "Could not save the file."),
            "savePermissionDenied": String(localized: "editor.error.permissionDenied", defaultValue: "You don't have permission to save this file."),
            "saveUnavailable": String(localized: "editor.error.saveUnavailable", defaultValue: "Saving is unavailable for this editor."),
            "saving": String(localized: "editor.status.saving", defaultValue: "Saving…"),
            "useDiskVersion": String(localized: "editor.conflict.useDiskVersion", defaultValue: "Use disk version")
        ]
    }

    /// JSON-encodes `object` for inlining into a `<script>` data block,
    /// escaping `</` so file content can never terminate the element early.
    static func jsonScriptLiteral(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MarkdownEditorPage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode editor page config"
            ])
        }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }

    static func htmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase SHA-256 hex digest. Pure Swift nibble encoding:
    /// `String(format:)` in hash paths is the known unbounded-memory P0 class
    /// in this repo.
    static func sha256Hex(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
