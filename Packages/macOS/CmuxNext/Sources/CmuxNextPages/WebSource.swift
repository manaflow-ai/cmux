public import Foundation
import CmuxNextActions

/// Where a page's document was served from, named in the page itself in DEV and NIGHTLY builds
/// (docs/cmux-next/hot-reload.md, Planned: "Show what's live"). The scheme handlers put one tag in the head of
/// the HTML they answer:
///
/// ```html
/// <meta name="cmux-web-source" content="dev-server http://127.0.0.1:4200/" data-label="Dev server" data-hint="…">
/// ```
///
/// and record it for the host, which the window's source chip reads: ``PageWebView/webSource`` for a
/// page, ``WebBundleServedViews/webSource(for:)`` for any served WebKit view, and
/// ``WebBundleServedViews/onWebSource`` on each change. The tag
/// lets page script read it too: it is in the document, not a response header, because a page's
/// policy allows it no fetch of its own document and Chromium keeps only the headers it knows. No
/// tag (Release, RC, an older app) means no source is shown, so the page bridge does not change.
public nonisolated enum WebSource: Sendable, Equatable {
    /// The live web loop's Vite server (``WebDevOverride/server``, a projection window's or the
    /// launch variable's ``PageDevServer``).
    case devServer(URL)
    /// The web-dev.json overlay of built bundles, at the commit its manifest names.
    case overlay(commit: String?)
    /// A verified web update (``WebBundleOverlay``), at its commit.
    case webUpdate(commit: String?)
    /// The web this build shipped with.
    case bundle

    /// The tag's `name`.
    public static let metaName = "cmux-web-source"

    /// Whether this build names its pages' source: DEV and NIGHTLY (``DevTools``).
    public static let isShown = DevTools.isEnabled

    /// The machine-readable value: the kind, then the server's URL or the commit when known.
    public var value: String {
        switch self {
        case .devServer(let url): "dev-server \(url.absoluteString)"
        case .overlay(let commit): ["overlay", commit].compactMap { $0 }.joined(separator: " ")
        case .webUpdate(let commit): ["web-update", commit].compactMap { $0 }.joined(separator: " ")
        case .bundle: "bundle"
        }
    }

    /// The chip's word for the kind, in the app's language.
    public var label: String {
        switch self {
        case .devServer: Self.t("webSource.label.devServer", "Dev server")
        case .overlay: Self.t("webSource.label.overlay", "Overlay")
        case .webUpdate: Self.t("webSource.label.webUpdate", "Web update")
        case .bundle: Self.t("webSource.label.bundle", "Bundle")
        }
    }

    /// The line the chip shows on hover: how to leave the live loop, or how to start it.
    public var hint: String {
        switch self {
        case .devServer, .overlay:
            Self.t("webSource.hint.live", "Live. Run cmux live stop to go back.")
        case .webUpdate, .bundle:
            Self.t("webSource.hint.start", "Edit this live: run cmux live start in a cmux checkout, or ask your agent to.")
        }
    }

    /// `raw` as a commit for the tag: up to 40 characters of `[0-9A-Za-z._-]`, else nil (an
    /// overlay installed with no known commit says `unknown`).
    static func commit(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != "unknown" else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return raw.count <= 40 && raw.allSatisfy(allowed.contains) ? raw : nil
    }

    /// The tag, its attribute values escaped.
    public var meta: String {
        "<meta name=\"\(Self.metaName)\" content=\"\(Self.escape(value))\" data-label=\"\(Self.escape(label))\" data-hint=\"\(Self.escape(hint))\">"
    }

    /// `html` with ``meta`` right after its `<head>` tag (else after `<html>`, else at its end, where
    /// a parser puts it in the body). Never before the doctype: that would put the page in quirks mode.
    public func marked(_ html: Data) -> Data {
        let tag = Data(meta.utf8)
        var out = html
        guard let at = Self.insertionPoint(in: html) else {
            out.append(tag)
            return out
        }
        out.insert(contentsOf: tag, at: at)
        return out
    }

    /// The byte offset just past the first `<head …>` (or `<html …>`) start tag, nil for neither.
    static func insertionPoint(in html: Data) -> Data.Index? {
        let bytes = Array(html.prefix(64 * 1024))
        for name in ["head", "html"] {
            if let end = startTagEnd(name, in: bytes) { return html.startIndex + end }
        }
        return nil
    }

    private static func startTagEnd(_ name: String, in bytes: [UInt8]) -> Int? {
        let open = Array("<\(name)".utf8)
        var index = 0
        while index + open.count < bytes.count {
            let matches = zip(open.indices, open).allSatisfy { offset, byte in
                Self.lowercased(bytes[index + offset]) == byte
            }
            let after = bytes[index + open.count]
            if matches, after == UInt8(ascii: ">") || after == UInt8(ascii: " ") || after == UInt8(ascii: "\n")
                || after == UInt8(ascii: "\t") || after == UInt8(ascii: "\r") {
                guard let close = bytes[(index + open.count)...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                return close + 1
            }
            index += 1
        }
        return nil
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
