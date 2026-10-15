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
/// `schemas/agent-url-policy/vectors.json`. WebKit panes do not apply it:
/// WebKit has no privileged pages behind these schemes, and Classic's WebKit
/// behavior stays unchanged.
public enum BrowserAgentURLPolicy {
    static let refusedSchemes: Set<String> = [
        "chrome", "chrome-extension", "chrome-untrusted", "chrome-search",
        "devtools", "chrome-devtools", "view-source",
        "cmux",
    ]
    /// Schemes whose inner URL names the origin.
    static let wrapperSchemes: Set<String> = ["blob", "filesystem"]
    /// The only `about:` pages Chromium does not turn into `chrome://` pages.
    static let plainAboutPages: Set<String> = ["blank", "srcdoc"]
    /// More nested wrappers than this are refused (fail closed).
    static let maxWrapperDepth = 2

    public static func refuses(_ url: URL) -> Bool { refuses(url.absoluteString) }

    public static func refuses(_ text: String) -> Bool { refuses(text, wrappers: 0) }

    static func refuses(_ text: String, wrappers: Int) -> Bool {
        if wrappers > maxWrapperDepth { return true }
        // Chromium drops tabs and newlines anywhere and trims leading spaces and control characters.
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))
        let trimmed = cleaned.drop { $0.unicodeScalars.allSatisfy { $0.value <= 0x20 } }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let scheme = trimmed[..<colon].lowercased()
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0) })
        else { return false }
        let rest = trimmed[trimmed.index(after: colon)...]
        if refusedSchemes.contains(scheme) { return true }
        if scheme == "cmux-page" { return isReservedPageHost(rest) }
        if wrapperSchemes.contains(scheme) { return refuses(String(rest), wrappers: wrappers + 1) }
        if scheme == "about" {
            let page = rest.prefix { $0 != "?" && $0 != "#" }.lowercased()
            return !plainAboutPages.contains(page)
        }
        return false
    }

    /// First-party `cmux-page://` hosts (`cmux`, `cmux.<id>`, single-label
    /// shared hosts) are refused; dotted third-party app ids stay allowed.
    /// Fail closed on an empty host or a percent escape.
    static func isReservedPageHost(_ rest: Substring) -> Bool {
        let afterSlashes = rest.drop { $0 == "/" || $0 == "\\" }
        var host = afterSlashes.prefix { !"/\\?#".contains($0) }
        if host.contains("%") { return true }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty || name == "cmux" || name.hasPrefix("cmux.") || !name.contains(".")
    }
}
