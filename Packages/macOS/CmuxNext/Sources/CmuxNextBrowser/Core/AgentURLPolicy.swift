public import Foundation

/// Pages an agent-driven tab never loads, shows or scripts: Chromium's own
/// WebUI, extension and DevTools pages (plans/cmux-next/passwords.md,
/// section 2). `chrome://password-manager` can put a device-auth prompt in
/// front of the person and then hand a saved password or a CSV export to its
/// script; `chrome://extensions` and `chrome://settings` change the profile.
/// One rule for every agent path: navigate, Back/Forward targets, reload and
/// evaluate while one shows, and a commit that reaches one anyway.
public nonisolated enum AgentURLPolicy {
    /// What an agent-driven tab shows instead of a refused page.
    public static let replacementURL = URL(string: BrowserNewTabPage.blankURL)

    static let refusedSchemes: Set<String> = [
        "chrome", "chrome-extension", "chrome-untrusted", "chrome-search",
        "devtools", "chrome-devtools", "view-source",
    ]
    /// Schemes whose inner URL names the origin.
    static let wrapperSchemes: Set<String> = ["blob", "filesystem"]
    /// The only `about:` pages Chromium does not turn into `chrome://` pages.
    static let plainAboutPages: Set<String> = ["blank", "srcdoc"]
    /// More nested wrappers than this are refused (fail closed); the C++ and
    /// Rust copies use the same limit (schemas/agent-url-policy/vectors.json).
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
        if wrapperSchemes.contains(scheme) { return refuses(String(rest), wrappers: wrappers + 1) }
        if scheme == "about" {
            let page = rest.prefix { $0 != "?" && $0 != "#" }.lowercased()
            return !plainAboutPages.contains(page)
        }
        return false
    }
}
