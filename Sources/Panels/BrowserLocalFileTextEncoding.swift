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

    /// A UTF-8 scalar is at most four bytes, so a cut scalar carries at most
    /// three of them before its lead byte.
    private static let maximumTruncatedScalarContinuationBytes = 3

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
        guard let prefix = try? handle.read(upToCount: sniffedByteCount),
              !prefix.isEmpty else {
            return false
        }
        if String(data: prefix, encoding: .utf8) != nil { return true }

        // A prefix that filled the window has more file behind it, so its last
        // scalar can be cut in half. Decode again without that scalar — but
        // only when the tail really is a cut scalar. Bytes that no scalar could
        // ever start mean the file is not UTF-8, and dropping them would hand a
        // legacy file the UTF-8 fallback it must not get.
        guard prefix.count == sniffedByteCount,
              let cutScalarByteCount = cutTrailingScalarByteCount(in: prefix) else {
            return false
        }
        return String(data: prefix.dropLast(cutScalarByteCount), encoding: .utf8) != nil
    }

    /// The length of a trailing scalar the prefix cut short, or `nil` when the
    /// tail is a whole scalar or is not UTF-8 at all.
    private static func cutTrailingScalarByteCount(in prefix: Data) -> Int? {
        var continuationByteCount = 0
        for byte in prefix.reversed() {
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationByteCount += 1
                guard continuationByteCount <= maximumTruncatedScalarContinuationBytes else {
                    return nil
                }
                continue
            }

            guard let scalarByteCount = scalarByteCount(forLeadByte: byte) else { return nil }
            let presentByteCount = continuationByteCount + 1
            return presentByteCount < scalarByteCount ? presentByteCount : nil
        }
        return nil
    }

    /// How many bytes the scalar starting with `byte` occupies, or `nil` when
    /// no UTF-8 scalar can start with it.
    private static func scalarByteCount(forLeadByte byte: UInt8) -> Int? {
        switch byte {
        case 0x00...0x7F:
            return 1
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }
}
