import CmuxNextBrowser
import CmuxNextCompat
import Foundation

/// Where a Cmd-clicked terminal link goes (cx-do47).
nonisolated enum TerminalLinkTarget: Equatable, Sendable {
    /// A URL with a scheme, or a web host typed without one (`localhost:3000/docs`, `docs.rs/serde`).
    case url(URL)
    /// A file or folder that exists.
    case file(URL, isDirectory: Bool)
}

/// Resolves the text Ghostty matched under a Cmd-click (cx-do47). Programs print paths in
/// prose: `is ready: ~/Desktop/reply.md.`, `"build-fleet/ORG-BACKUP.md",`, `src/app.ts:3:5`.
/// The surrounding quotes and trailing punctuation go, as does a `:line:col`; a relative path
/// resolves against the terminal's directory, then the git root above it. Only a path that
/// exists is a link. Text without a scheme is a web link only when its host is localhost, an
/// IP address with a port, or a name under a real top-level domain, so `build-fleet/x.md`
/// never opens https://build-fleet/x.md.
nonisolated enum TerminalLinkResolver {
    /// The target of `text`, or nil when it is no link (a path that exists nowhere, a bogus
    /// host). Reads the file system: call it off the main thread.
    static func resolve(_ text: String, cwd: String?, allowsLocalFiles: Bool = true,
                        localHostNames: Set<String>? = nil, fileManager: FileManager = .default,
                        isTopLevelDomain: (String) -> Bool = { $0.isTopLevelDomain }) -> TerminalLinkTarget? {
        let trimmed = trim(text)
        guard safeTerminalText(trimmed) else { return nil }
        let localHostNames = localHostNames ?? localFileHostNames()
        if hasScheme(trimmed), let url = URL(string: trimmed) {
            if url.isFileURL {
                guard allowsLocalFiles, safeTerminalURL(url), localFile(url, hostNames: localHostNames) else { return nil }
                return existing(url.path, fileManager: fileManager)
            }
            guard !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  safeTerminalURL(url), webURL(url) else { return nil }
            return .url(url)
        }
        guard allowsLocalFiles else {
            return safeWebURL(trimmed, isTopLevelDomain: isTopLevelDomain).map(TerminalLinkTarget.url)
        }
        let path = withoutLocation(trimmed)
        for candidate in candidates(path, cwd: cwd, hostNames: localHostNames, fileManager: fileManager) {
            if let target = existing(candidate, fileManager: fileManager) { return target }
        }
        return safeWebURL(trimmed, isTopLevelDomain: isTopLevelDomain).map(TerminalLinkTarget.url)
    }

    private static let openers: Set<Character> = ["\"", "'", "`", "“", "‘", "<", "[", "{", "("]
    private static let closers: Set<Character> = ["\"", "'", "`", "”", "’", ">", "]", "}", ".", ",", ";", ":", "!", "?"]

    /// `text` without surrounding quotes and brackets and trailing punctuation; a closing
    /// parenthesis stays when it closes one in the text (`wiki/Foo_(bar)`).
    static func trim(_ text: String) -> String {
        var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = value.first, openers.contains(first) { value.removeFirst() }
        while let last = value.last {
            let unbalanced = last == ")" && value.count(where: { $0 == "(" }) < value.count(where: { $0 == ")" })
            guard closers.contains(last) || unbalanced else { break }
            value.removeLast()
        }
        return String(value)
    }

    /// `mailto:`, `https://`; not `localhost:3000` or `app.ts:3` (a port or a line).
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), let first = text.first, first.isASCII, first.isLetter else { return false }
        let scheme = text[..<colon]
        guard scheme.count > 1, scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return false }
        return text[text.index(after: colon)...].first.map { !$0.isNumber } ?? false
    }

    /// The `:line` or `:line:col` after a printed path (`src/app.ts:3:5` is line 3, column 5),
    /// as surrounding quotes and punctuation are trimmed; nil without one, or for a URL.
    static func location(_ text: String) -> (line: Int, column: Int?)? {
        let trimmed = trim(text)
        guard !hasScheme(trimmed) else { return nil }
        var numbers: [Int] = []
        var value = Substring(trimmed)
        for _ in 0..<2 {
            guard let colon = value.lastIndex(of: ":"), colon != value.startIndex else { break }
            let digits = value[value.index(after: colon)...]
            guard !digits.isEmpty, digits.count < 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { break }
            numbers.insert(number, at: 0)
            value = value[..<colon]
        }
        guard let line = numbers.first, line > 0 else { return nil }
        return (line, numbers.count > 1 ? numbers[1] : nil)
    }

    /// `path` without a trailing `:line` or `:line:col`.
    private static func withoutLocation(_ path: String) -> String {
        var value = Substring(path)
        for _ in 0..<2 {
            guard let colon = value.lastIndex(of: ":"), colon != value.startIndex else { break }
            let digits = value[value.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
            value = value[..<colon]
        }
        return String(value)
    }

    /// Absolute paths as they are; `~` expanded; a relative path under `cwd`, then under the git
    /// root above it.
    private static func candidates(_ path: String, cwd: String?, hostNames: Set<String>, fileManager: FileManager) -> [String] {
        if path.hasPrefix("~") { return [(path as NSString).expandingTildeInPath] }
        if path.hasPrefix("/") { return [path] }
        guard let cwd = cwd.flatMap({ directory($0, hostNames: hostNames) }) else { return [] }
        var bases = [cwd]
        if let root = gitRoot(above: cwd, fileManager: fileManager), root != cwd { bases.append(root) }
        return bases.map { ($0 as NSString).appendingPathComponent(path) }
    }

    /// The shell's directory as a path (a `file://` URL from OSC 7 too).
    private static func directory(_ cwd: String, hostNames: Set<String>) -> String? {
        if cwd.hasPrefix("/") { return (cwd as NSString).standardizingPath }
        guard let url = URL(string: cwd), localFile(url, hostNames: hostNames), !url.path.isEmpty else { return nil }
        return (url.path as NSString).standardizingPath
    }

    /// File URLs from a terminal must name this Mac, never an arbitrary authority.
    private static func localFile(_ url: URL, hostNames: Set<String>) -> Bool {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return true }
        return hostNames.contains(host)
    }

    /// Host names OSC 7 emitted by a shell on this Mac may use.
    private static func localFileHostNames() -> Set<String> {
        let kernel = MacName().kernelHostName().lowercased()
        var names: Set<String> = ["localhost"]
        if !kernel.isEmpty {
            names.insert(kernel)
            names.insert(kernel + ".local")
        }
        return names
    }

    /// Explicit terminal URLs are web-only and never carry credentials.
    private static func webURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }

    /// Reject invisible or control characters before URL parsing can escape them.
    private static func safeTerminalText(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || invisibleFormat(scalar.value)
        }
    }

    /// Percent escapes must not smuggle controls or invisible formatting past the raw check.
    private static func safeTerminalURL(_ url: URL) -> Bool {
        guard let decoded = url.absoluteString.removingPercentEncoding else { return false }
        return safeTerminalText(decoded)
    }

    private static func invisibleFormat(_ value: UInt32) -> Bool {
        value == 0x00AD || value == 0x061C || value == 0x180E
            || (0x200B...0x200F).contains(value) || (0x202A...0x202E).contains(value)
            || (0x2060...0x2064).contains(value) || (0x2066...0x206F).contains(value)
            || value == 0xFEFF || (0xFFF9...0xFFFB).contains(value)
    }

    /// The nearest folder at or above `directory` holding `.git`.
    private static func gitRoot(above directory: String, fileManager: FileManager) -> String? {
        var folder = directory
        for _ in (directory as NSString).pathComponents {
            if fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func existing(_ path: String, fileManager: FileManager) -> TerminalLinkTarget? {
        let standardized = (path as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory) else { return nil }
        return .file(URL(fileURLWithPath: standardized, isDirectory: isDirectory.boolValue), isDirectory: isDirectory.boolValue)
    }

    /// `text` as a web URL when its host can be one: localhost (http), an IPv4 address with a
    /// port (http), or a dotted name whose last label is a top-level domain (https). A bare
    /// name with no path or port (`README.md`, `notes.sh`) is a file name, not a host.
    private static func webURL(_ text: String, isTopLevelDomain: (String) -> Bool) -> URL? {
        guard !text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return nil }
        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        var host = authority, port: Substring?
        if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            let digits = authority[authority.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            port = digits
        }
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") { return URL(string: "http://" + text) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) {
            return port == nil ? nil : URL(string: "http://" + text)
        }
        guard authority.count < text.count || port != nil || name.hasPrefix("www.") else { return nil }
        guard labels.count >= 2, let last = labels.last,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              isTopLevelDomain(String(last)) else { return nil }
        return URL(string: "https://" + text)
    }

    private static func safeWebURL(_ text: String, isTopLevelDomain: (String) -> Bool) -> URL? {
        guard let url = webURL(text, isTopLevelDomain: isTopLevelDomain), safeTerminalURL(url) else { return nil }
        return url
    }
}
