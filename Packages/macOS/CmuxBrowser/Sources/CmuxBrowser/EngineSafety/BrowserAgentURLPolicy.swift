public import Foundation

/// Pages an agent-driven (socket or CLI) navigation never loads, shows or
/// scripts in a Chromium pane: Chromium's own WebUI, extension and DevTools
/// pages, and cmux's internal pages. `chrome://password-manager` can put a
/// device-auth prompt in front of the person and then hand a saved password to
/// its script; `chrome://extensions` and `chrome://settings` change the
/// profile. One rule for every agent path: navigate, Back/Forward targets,
/// reload and evaluate while one shows.
///
/// Same rule as cmux Next's `AgentURLPolicy` and the CEF shim's
/// `AgentRefusesURL` (CEFShim/src/agent_url_policy.h); all pass
/// `schemas/agent-url-policy/vectors.json`. It works on the UTF-8 bytes with
/// ASCII-only classes, exactly as the C++ copy does: Swift's grapheme-based
/// `String` search would miss a `:` followed by a combining mark, which
/// Chromium drops. WebKit panes do not apply it: WebKit has no privileged
/// pages behind these schemes, and Classic's WebKit behavior stays unchanged.
extension String {
    /// True when an agent-driven navigation in a Chromium pane must not load
    /// this URL text.
    public var isRefusedForAgentNavigation: Bool {
        AgentURLRule.refuses(Array(utf8), wrappers: 0)
    }
}

extension URL {
    /// True when an agent-driven navigation in a Chromium pane must not load
    /// this URL (see `String.isRefusedForAgentNavigation`).
    public var isRefusedForAgentNavigation: Bool { absoluteString.isRefusedForAgentNavigation }
}

/// The byte-level rule behind `String.isRefusedForAgentNavigation`.
private enum AgentURLRule {
    static let refusedSchemes: Set<[UInt8]> = Set([
        "chrome", "chrome-extension", "chrome-untrusted", "chrome-search",
        "devtools", "chrome-devtools", "view-source",
        "cmux",
    ].map { Array($0.utf8) })
    /// Schemes whose inner URL names the origin.
    static let wrapperSchemes: Set<[UInt8]> = [Array("blob".utf8), Array("filesystem".utf8)]
    /// The only `about:` pages Chromium does not turn into `chrome://` pages.
    static let plainAboutPages: Set<[UInt8]> = [Array("blank".utf8), Array("srcdoc".utf8)]
    /// More nested wrappers than this are refused (fail closed).
    static let maxWrapperDepth = 2

    static func refuses(_ input: [UInt8], wrappers: Int) -> Bool {
        if wrappers > maxWrapperDepth { return true }
        // Chromium drops tabs and newlines anywhere and trims leading bytes <= 0x20.
        let text = input.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        guard let start = text.firstIndex(where: { $0 > 0x20 }),
              let colon = text[start...].firstIndex(of: 0x3A), colon != start else { return false }
        guard isASCIILetter(text[start]) else { return false }
        var scheme: [UInt8] = []
        for byte in text[start..<colon] {
            guard isASCIIAlphanumeric(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E else { return false }
            scheme.append(lowerASCII(byte))
        }
        let rest = Array(text[(colon + 1)...])
        if refusedSchemes.contains(scheme) { return true }
        if scheme == Array("cmux-page".utf8) { return isReservedPageHost(rest) }
        if wrapperSchemes.contains(scheme) { return refuses(rest, wrappers: wrappers + 1) }
        if scheme == Array("about".utf8) {
            let page = rest.prefix { $0 != 0x3F && $0 != 0x23 }.map(lowerASCII)
            return !plainAboutPages.contains(page)
        }
        return false
    }

    /// First-party `cmux-page://` hosts (`cmux`, `cmux.<id>`, single-label
    /// shared hosts) are refused; dotted third-party app ids stay allowed.
    /// Fail closed on an empty host, a percent escape, or any non-ASCII byte
    /// (`cmux-page` is a standard scheme, so Chromium would map a fullwidth or
    /// IDNA-ignored host onto `cmux.<id>`).
    static func isReservedPageHost(_ rest: [UInt8]) -> Bool {
        let afterSlashes = rest.drop { $0 == 0x2F || $0 == 0x5C }
        var host = Array(afterSlashes.prefix { $0 != 0x2F && $0 != 0x5C && $0 != 0x3F && $0 != 0x23 })
        if host.contains(0x25) || host.contains(where: { $0 >= 0x80 }) { return true }
        if let at = host.lastIndex(of: 0x40) { host = Array(host[(at + 1)...]) }
        if let port = host.firstIndex(of: 0x3A) { host = Array(host[..<port]) }
        var name = host.map(lowerASCII)
        while name.last == 0x2E { name.removeLast() }
        let cmux = Array("cmux".utf8)
        return name.isEmpty || name == cmux || name.starts(with: cmux + [0x2E]) || !name.contains(0x2E)
    }

    static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || (0x30...0x39).contains(byte)
    }

    static func lowerASCII(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }
}
