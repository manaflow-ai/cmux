import CmuxNextBrowser
public import Foundation

/// Where a Cmd-clicked terminal link goes (cx-do47).
public nonisolated enum TerminalLinkTarget: Equatable, Sendable {
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
public nonisolated struct TerminalLinkResolver {
    public init() {}

    /// The target of `text`, or nil when it is no link (a path that exists nowhere, a bogus
    /// host). Reads the file system: call it off the main thread. `isTopLevelDomain` defaults to
    /// the browser's list (`String.isTopLevelDomain`).
    public func resolve(_ text: String, cwd: String?, fileManager: FileManager = .default,
                        isTopLevelDomain: ((String) -> Bool)? = nil) -> TerminalLinkTarget? {
        let trimmed = Self.trim(text)
        guard !trimmed.isEmpty, !trimmed.contains("\u{0}") else { return nil }
        if Self.hasScheme(trimmed), let url = URL(string: trimmed) {
            return url.isFileURL ? Self.existing(url.path, fileManager: fileManager) : .url(url)
        }
        let path = Self.withoutLocation(trimmed)
        for candidate in Self.candidates(path, cwd: cwd, fileManager: fileManager) {
            if let target = Self.existing(candidate, fileManager: fileManager) { return target }
        }
        return Self.webURL(trimmed, isTopLevelDomain: isTopLevelDomain ?? { $0.isTopLevelDomain }).map(TerminalLinkTarget.url)
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
    private static func candidates(_ path: String, cwd: String?, fileManager: FileManager) -> [String] {
        if path.hasPrefix("~") { return [(path as NSString).expandingTildeInPath] }
        if path.hasPrefix("/") { return [path] }
        guard let cwd = cwd.flatMap(directory) else { return [] }
        var bases = [cwd]
        if let root = gitRoot(above: cwd, fileManager: fileManager), root != cwd { bases.append(root) }
        return bases.map { ($0 as NSString).appendingPathComponent(path) }
    }

    /// The shell's directory as a path (a `file://` URL from OSC 7 too).
    private static func directory(_ cwd: String) -> String? {
        if cwd.hasPrefix("/") { return (cwd as NSString).standardizingPath }
        guard let url = URL(string: cwd), url.isFileURL, !url.path.isEmpty else { return nil }
        return (url.path as NSString).standardizingPath
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
}
