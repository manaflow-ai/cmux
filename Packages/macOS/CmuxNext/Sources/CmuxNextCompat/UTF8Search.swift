import Foundation

/// Byte searches over a protocol frame's UTF-8 (`utf8Contains`, `utf8ContainsAny`, `utf8HasValue`), for the hot paths that look for a JSON name or marker in text they do
/// not parse.
///
/// `String.contains(_:)` with a string argument is Foundation's `StringProtocol.range(of:)`: a Unicode-aware compare that
/// walks the text one `Substring` index at a time. On Leo's NIGHTLY (2026-11-21, load 164-228) the agent panes' inbound
/// queues spent about two thirds of their time in it: every streaming `session/update` was scanned in full three times
/// for markers it does not hold (``AcpmuxPaneSocket`` page waits). A `memmem` over the same bytes reads the frame once
/// per needle at memory speed. The DevTools router hit the same cost on 2026-10-29 (``DevToolsMessageHead``).
///
/// The needles are protocol names and quoted JSON keys, so a byte match is the match: no normalization is wanted.
public nonisolated extension String {
    /// Whether `needle`'s UTF-8 bytes occur in this text's (a native string is read in place; a bridged one is
    /// copied once).
    /// - Parameter needle: The text to look for; an empty needle is always found.
    /// - Returns: True when `needle` occurs anywhere in the text.
    func utf8Contains(_ needle: String) -> Bool {
        var haystack = self
        return haystack.withUTF8 { bytes in Self.utf8(bytes, contain: needle) }
    }

    /// Whether any of `needles` occurs in this text, reading its bytes in place once.
    /// - Parameter needles: The texts to look for.
    /// - Returns: True when one of them occurs.
    func utf8ContainsAny(_ needles: [String]) -> Bool {
        var haystack = self
        return haystack.withUTF8 { bytes in needles.contains { Self.utf8(bytes, contain: $0) } }
    }

    /// Whether `needle`'s UTF-8 bytes occur in `bytes`.
    private static func utf8(_ bytes: UnsafeBufferPointer<UInt8>, contain needle: String) -> Bool {
        var pattern = needle
        return pattern.withUTF8 { wanted in
            guard !wanted.isEmpty else { return true }
            guard wanted.count <= bytes.count, let base = bytes.baseAddress, let target = wanted.baseAddress else { return false }
            return memmem(base, bytes.count, target, wanted.count) != nil
        }
    }

    /// Whether some `"key"` in this JSON text, at any depth, has a plain string value in `values` (`"kind":"turn_end"`, with
    /// any whitespace around the colon). One `memmem` hop per occurrence of the key; a value with an escape never
    /// matches (no protocol value here has one).
    /// - Parameters:
    ///   - key: The JSON key, unquoted.
    ///   - values: The string values looked for.
    /// - Returns: True when one occurrence of the key has one of the values.
    func utf8HasValue(of key: String, in values: Set<String>) -> Bool {
        var haystack = self
        let quoted = Array("\"\(key)\"".utf8)
        return haystack.withUTF8 { bytes in
            guard let base = bytes.baseAddress, quoted.count <= bytes.count else { return false }
            let count = bytes.count
            var from = 0
            while from + quoted.count <= count {
                guard let hit = quoted.withUnsafeBytes({ memmem(base + from, count - from, $0.baseAddress!, quoted.count) })
                else { return false }
                var i = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit)) + quoted.count
                from = i
                func space(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
                while i < count, space(base[i]) { i += 1 }
                guard i < count, base[i] == 0x3A else { continue } // `:` (a value equal to the key's name is no key)
                i += 1
                while i < count, space(base[i]) { i += 1 }
                guard i < count, base[i] == 0x22 else { continue }
                let start = i + 1
                var end = start
                while end < count, base[end] != 0x22, base[end] != 0x5C { end += 1 }
                guard end < count, base[end] == 0x22 else { continue }
                if values.contains(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)) {
                    return true
                }
                from = end + 1
            }
            return false
        }
    }
}
