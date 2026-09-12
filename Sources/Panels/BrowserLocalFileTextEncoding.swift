import Foundation
import WebKit

/// Picks the fallback text encoding WebKit uses for a document that declares no
/// charset of its own.
///
/// WebKit derives that fallback from the system locale — `ks_c_5601-1987` on a
/// Korean Mac, `windows-1252` on a Western one — and a local text file has no
/// way to override it: a `file://` navigation carries no `Content-Type` header,
/// and plain text has no `<meta charset>`. So opening a UTF-8 `.md`, `.txt`, or
/// `.csv` file in a browser pane decodes it through the locale fallback and
/// renders mojibake instead of text
/// (https://github.com/manaflow-ai/cmux/issues/12432).
///
/// Only local files whose own bytes decode as UTF-8 switch the fallback.
/// Remote pages keep WebKit's locale fallback, so a charset-less legacy page
/// decodes exactly as it does today, and a local file that really is EUC-KR or
/// Shift_JIS keeps rendering too.
enum BrowserLocalFileTextEncoding {
    static let utf8EncodingName = "UTF-8"

    /// Bytes read from the head of the file to decide whether it is UTF-8.
    /// Large enough to cover what a reader sees first, small enough to stay off
    /// the navigation's critical path.
    static let sniffedByteCount = 64 * 1024

    /// A UTF-8 scalar is at most four bytes, so a prefix can end at most three
    /// bytes into one. Retry the decode after dropping those trailing bytes
    /// before calling the file non-UTF-8.
    private static let maximumTruncatedScalarBytes = 3

    private static let setDefaultTextEncodingNameSelector = NSSelectorFromString(
        "_setDefaultTextEncodingName:"
    )

    private static let defaultTextEncodingNameSelector = NSSelectorFromString(
        "_defaultTextEncodingName"
    )

    /// WebKit's own locale-derived fallback, read from a pristine `WKPreferences`
    /// so it survives whatever the browser's live preferences were last set to.
    @MainActor
    private static let localeFallbackEncodingName: String? = {
        let preferences = WKPreferences()
        guard preferences.responds(to: defaultTextEncodingNameSelector) else { return nil }
        return preferences
            .perform(defaultTextEncodingNameSelector)?
            .takeUnretainedValue() as? String
    }()

    /// Applies the fallback encoding for a main-frame navigation to `url`.
    /// WebKit reads the preference when it creates the document, so this must
    /// run before the navigation is allowed.
    @MainActor
    static func applyDefaultTextEncoding(for url: URL?, in webView: WKWebView) {
        let preferences = webView.configuration.preferences
        guard preferences.responds(to: setDefaultTextEncodingNameSelector) else { return }
        let encodingName = shouldUseUTF8Fallback(for: url)
            ? utf8EncodingName
            : localeFallbackEncodingName
        _ = preferences.perform(setDefaultTextEncodingNameSelector, with: encodingName)
    }

    /// True when `url` is a local file whose leading bytes decode as UTF-8.
    static func shouldUseUTF8Fallback(for url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard var prefix = try? handle.read(upToCount: sniffedByteCount),
              !prefix.isEmpty else {
            return false
        }

        for _ in 0...maximumTruncatedScalarBytes {
            if String(data: prefix, encoding: .utf8) != nil { return true }
            guard prefix.count > 1 else { return false }
            prefix = prefix.dropLast()
        }
        return false
    }
}
