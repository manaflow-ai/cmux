public import Foundation

/// Reads a palette query as a path or a web address.
///
/// A path is absolute (`/…`), home-relative (`~`, `~/…`), or relative to
/// the focused pane's folder (`./…`, `../…`, `a/b`, or a bare name with a
/// dot such as `README.md`); it must exist. A web address has an `http` or
/// `https` scheme, or is a bare host (`github.com/x`, `localhost:3000`,
/// `10.0.0.2:8080`). A path that exists wins over a host reading. Words
/// after the first space are the trailing text, unless the whole query is
/// itself an existing path (paths with spaces).
///
/// File system access goes through `kind`, so tests pass a fake.
public struct PaletteQueryTargetParser: Sendable {
    /// What is at a path: a file, a folder, or nothing.
    public enum Kind: Sendable { case file, folder }

    public var home: String
    public var kind: @Sendable (String) -> Kind?

    public init(home: String = NSHomeDirectory(), kind: @escaping @Sendable (String) -> Kind? = PaletteQueryTargetParser.diskKind) {
        self.home = home
        self.kind = kind
    }

    /// The real file system.
    public static let diskKind: @Sendable (String) -> Kind? = { path in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .folder : .file
    }

    /// Hosts typed without a scheme or a path still read as web addresses
    /// for these endings (`example.com`); any other ending needs a path or a
    /// port (`foo.md` is a file name, `foo.md/x` a page).
    static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "app", "co", "sh", "so", "gg", "me", "tv", "xyz", "edu", "gov",
        "us", "uk", "de", "fr", "jp", "cn", "ca", "au", "in", "ru", "br", "nl", "eu", "info", "tech", "cloud", "site",
    ]

    /// The place `query` names, with any words after it; nil when it names none.
    /// `base` is the focused pane's folder, for relative paths.
    public func parse(_ query: String, base: String?) -> PaletteQueryMatch? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A path with spaces: the whole query, when it exists.
        if text.contains(" "), let target = path(text, base: base) { return PaletteQueryMatch(target: target) }
        let head: String
        let rest: String?
        if let space = text.firstIndex(where: \.isWhitespace) {
            head = String(text[..<space])
            let tail = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = tail.isEmpty ? nil : tail
        } else {
            head = text
            rest = nil
        }
        if let target = path(head, base: base) ?? web(head) { return PaletteQueryMatch(target: target, trailingText: rest) }
        return nil
    }

    /// An existing file or folder at `token`, read as a path.
    func path(_ token: String, base: String?) -> PaletteQueryTarget? {
        var raw = token
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { raw = url.path }
        let absolute: String
        if raw == "~" || raw.hasPrefix("~/") {
            absolute = home + raw.dropFirst(1)
        } else if raw.hasPrefix("/") {
            absolute = raw
        } else {
            // Relative: only path-like text, so a plain search word never becomes a path.
            let pathLike = raw.hasPrefix("./") || raw.hasPrefix("../") || raw == "." || raw == ".." || raw.contains("/") || raw.contains(".")
            guard pathLike, let base, base.hasPrefix("/") else { return nil }
            absolute = (base as NSString).appendingPathComponent(raw)
        }
        let standardized = (absolute as NSString).standardizingPath
        guard let found = kind(standardized) else { return nil }
        let url = URL(fileURLWithPath: standardized, isDirectory: found == .folder)
        return found == .folder ? .folder(url) : .file(url)
    }

    /// A web address at `token`.
    func web(_ token: String) -> PaletteQueryTarget? {
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: token), let host = url.host(), !host.isEmpty else { return nil }
            return .web(url)
        }
        guard !token.contains("://"), !token.hasPrefix("/"), !token.hasPrefix("~"), !token.hasPrefix(".") else { return nil }
        let hostPart = String(token.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let hasMore = hostPart.count < token.count
        var host = hostPart
        var hasPort = false
        if let colon = hostPart.lastIndex(of: ":") {
            let port = hostPart[hostPart.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber), port.count <= 5 else { return nil }
            host = String(hostPart[..<colon])
            hasPort = true
        }
        let local = host.lowercased() == "localhost"
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let isIPv4 = labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }
        let validLabels = labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
        let scheme: String
        if local || isIPv4 {
            guard local ? (hasPort || hasMore) : true else { return nil }
            scheme = "http"
        } else {
            guard labels.count >= 2, validLabels, let tld = labels.last?.lowercased(), tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
            guard Self.commonTLDs.contains(tld) || hasMore || hasPort else { return nil }
            scheme = "https"
        }
        guard let url = URL(string: "\(scheme)://\(token)"), url.host() != nil else { return nil }
        return .web(url)
    }
}
