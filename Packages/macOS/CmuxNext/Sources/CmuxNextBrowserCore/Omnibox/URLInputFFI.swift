import CCmuxURLInputFFI
import Foundation

/// The typed address-bar policy's C ABI (cmux-tui/crates/cmux-url-input,
/// include/cmux_url_input.h): BrowserURLResolver, ChromiumInternalURL and
/// ChromiumPageRoute ask Rust and keep no rules of their own. Every call is
/// pure and thread-safe and runs on every key. The header's anonymous enums
/// import as `Int`, so codes are compared as `Int`.
nonisolated enum URLInputFFI {
    /// The code and text of a call that writes `out[0..<*out_len]`; the text is
    /// nil when nothing was written or the call failed. ERR_SHORT is retried once
    /// with the size the call asked for.
    static func text(
        _ call: (UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<Int>) -> Int32
    ) -> (code: Int, text: String?) {
        var capacity = 512
        for _ in 0..<2 {
            var length = 0
            var buffer = [UInt8](repeating: 0, count: capacity)
            let code: Int = buffer.withUnsafeMutableBufferPointer { out in
                // capacity is never 0, so the base address is never nil; a nil one reads as "nothing written".
                guard let base = out.baseAddress else { return CMUX_URL_INPUT_ERR_SHORT }
                return Int(call(base, out.count, &length))
            }
            if code == CMUX_URL_INPUT_ERR_SHORT, length > capacity {
                capacity = length
                continue
            }
            guard code >= 0, length > 0, length <= capacity else { return (code, nil) }
            return (code, String(decoding: buffer[0..<length], as: UTF8.self))
        }
        return (CMUX_URL_INPUT_ERR_SHORT, nil)
    }

    /// `body` with `text`'s UTF-8 bytes (a null pointer only when empty).
    static func withBytes<R>(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        var text = text
        return text.withUTF8 { body($0.baseAddress, $0.count) }
    }

    /// `cmux_url_input_resolve_typed`: the URL to load, nil for a search.
    static func resolveTyped(_ input: String, home: String, allowsChromium: Bool) -> String? {
        let flags = UInt32(allowsChromium ? CMUX_URL_INPUT_FLAG_ALLOWS_CHROMIUM : 0)
        return withBytes(input) { inputBytes, inputLength in
            withBytes(home) { homeBytes, homeLength in
                text { out, cap, length in
                    cmux_url_input_resolve_typed(inputBytes, inputLength, homeBytes, homeLength, flags, out, cap, length)
                }
            }
        }.text
    }

    static func containsPairingLink(_ text: String) -> Bool {
        withBytes(text) { Int(cmux_url_input_contains_pairing_link($0, $1)) == CMUX_URL_INPUT_FOUND }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        withBytes(host) { Int(cmux_url_input_is_loopback_host($0, $1)) == CMUX_URL_INPUT_FOUND }
    }

    /// `cmux_url_input_chromium_internal_url`: the canonical page, nil for none.
    static func chromiumInternalURL(_ input: String) -> String? {
        withBytes(input) { bytes, count in
            text { out, cap, length in cmux_url_input_chromium_internal_url(bytes, count, out, cap, length) }
        }.text
    }

    /// `cmux_url_input_chromium_page_route`: a CMUX_URL_INPUT_ROUTE_* kind and
    /// the URL it carries (CMUX_PAGE and CHROMIUM only).
    static func chromiumPageRoute(_ url: String) -> (kind: Int, url: String?) {
        withBytes(url) { bytes, count in
            text { out, cap, length in cmux_url_input_chromium_page_route(bytes, count, out, cap, length) }
        }
    }
}
