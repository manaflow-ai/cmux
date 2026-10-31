import Foundation

/// A file, directory or link a session referenced: terminal output, or an
/// agent session's tool calls, attachments and answers. (The name predates
/// agent sessions; `SessionArtifact` is the same type.)
public struct TerminalArtifact: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case directory, image, video, html, markdown, code, text, pdf, binary, link
        /// Audio Quick Look plays (m4a, mp3, wav, ...).
        case audio
        /// A document Quick Look renders (Office, iWork, RTF, ...).
        case document
    }

    /// The reference as written, without a `:line:col` suffix.
    public var id: String { reference }
    public let reference: String
    public var kind: Kind
    /// The line from a `path:line[:col]` reference.
    public var line: Int?
    /// Order of first appearance.
    public var order: Int
    /// How the session referenced it ("Edited · +12 −4", "Attached", "Linked in the answer"); nil for terminal output.
    public var detail: String?

    public init(reference: String, kind: Kind, line: Int? = nil, order: Int = 0, detail: String? = nil) {
        self.reference = reference
        self.kind = kind
        self.line = line
        self.order = order
        self.detail = detail
    }

    public var name: String {
        if kind == .link { return URL(string: reference)?.host() ?? reference }
        let trimmed = reference.hasSuffix("/") ? String(reference.dropLast()) : reference
        return trimmed.split(separator: "/").last.map(String.init) ?? reference
    }

    public var fileExtension: String {
        guard kind != .link, let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public var systemImage: String {
        switch kind {
        case .directory: "folder.fill"
        case .image: "photo"
        case .video: "play.rectangle"
        case .html: "globe"
        case .markdown: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .pdf: "doc.fill"
        case .binary: "gearshape.2"
        case .link: "link"
        case .audio: "waveform"
        case .document: "doc.richtext.fill"
        }
    }

    public static func kind(forExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico": .image
        case "mp4", "mov", "m4v", "webm", "3gp": .video
        case "m4a", "mp3", "wav", "aac", "aif", "aiff", "caf", "flac", "opus": .audio
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote", "rtf", "rtfd", "usdz", "epub": .document
        // SVG is markup: UIImage can't decode it, the web preview draws it (scripts off).
        case "html", "htm", "svg": .html
        case "md", "markdown": .markdown
        case "swift", "rs", "zig", "c", "h", "m", "go", "py", "js", "ts", "tsx", "jsx", "sh", "toml", "json", "yml",
             "yaml", "css", "sql", "rb", "java", "kt", "kts", "cpp", "hpp", "mm", "php", "lua",
             "scala", "dart", "ex", "exs", "hs", "vue", "svelte", "scss", "less", "xml", "plist", "ini", "conf", "cfg",
             "gradle", "zsh", "bash", "fish", "mjs", "cjs", "proto", "graphql", "tf", "nix": .code
        case "txt", "log", "lock", "csv", "tsv", "diff", "patch": .text
        case "pdf": .pdf
        default: nil
        }
    }
}

extension TerminalArtifact {
    /// Lines of code or text a grid tile shows.
    public static let thumbnailExcerptLines = 12

    /// A grid tile's text excerpt: the first lines, tabs as four spaces, trailing blank
    /// lines dropped. `nil` when there is nothing to show.
    public static func thumbnailExcerpt(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\t", with: "    ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(thumbnailExcerptLines)
            .map(String.init)
        let kept = Array(lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed())
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}

/// What an artifact preview shows.
public enum ArtifactContent: Sendable {
    case text(String)
    case image(Data)
    /// A playable local file (video).
    case file(URL)
    case web(URL)
    case directory([TerminalArtifact])
    case pdf(Data)
    case binary(description: String)
    /// A local copy for Quick Look (audio, Office and iWork documents, and
    /// anything else it can show); a share sheet when it can't.
    case quickLook(URL)
    /// A downloaded snapshot retained for exactly as long as its consumers need it.
    case ownedFile(ManagedPreviewFile, isVideo: Bool)
}

extension ArtifactContent {
    /// The first line of an empty file's `binary` description.
    public static let emptyFileLine = "Empty file"

    /// A file with no bytes: nothing to preview (no Preview/Source toggle).
    public var isEmptyFile: Bool {
        if case .binary(let description) = self {
            return description == Self.emptyFileLine || description.hasPrefix(Self.emptyFileLine + "\n")
        }
        return false
    }
}

public typealias SessionArtifact = TerminalArtifact

/// Loads artifact contents: from the Mac over the `file` link service
/// (`LinkFileArtifactSource`), from inline data, or from the mock.
public protocol ArtifactSource: Sendable {
    func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent
}

public struct ArtifactNotFound: Error, LocalizedError {
    public let reference: String
    public init(reference: String) { self.reference = reference }
    public var errorDescription: String? { "\(reference) is not available from this Mac." }
}

/// A preview that can't load, with the sentence to show.
public struct ArtifactUnavailable: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Files and Links with no Mac to read from (a terminal or chat that is not
/// connected yet): every preview says so instead of showing sample files.
public struct UnavailableArtifactSource: ArtifactSource {
    public let message: String

    public init(message: String = "Connect to your Mac to preview this.") {
        self.message = message
    }

    public func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
        throw ArtifactUnavailable(message)
    }
}

/// Finds paths and URLs in terminal output: strips escape sequences, keeps a
/// partial last line across chunks, and reports each reference once.
public struct ArtifactExtractor: Sendable {
    private var partial = ""
    private var seen: Set<String> = []
    private var count = 0

    public init() {}

    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s'"<>`)\]]+"#)
    private static let path = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-])((?:~|\.{1,2})?/?(?:[A-Za-z0-9_.@+\-]+/)*[A-Za-z0-9_@+\-][A-Za-z0-9_.@+\-]*(?:\.[A-Za-z][A-Za-z0-9]{0,7})?/?)(?::(\d+)(?::\d+)?)?"#)
    private static let escapes = try! NSRegularExpression(pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])")

    public mutating func scan(_ data: Data) -> [TerminalArtifact] {
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: CharacterSet.newlines)
        partial = lines.removeLast()
        if partial.count > 4096 { partial = "" }
        var found: [TerminalArtifact] = []
        for line in lines where !line.isEmpty {
            found += scanLine(line)
        }
        return found
    }

    public mutating func scanLine(_ raw: String) -> [TerminalArtifact] {
        let line = Self.escapes.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        let ns = line as NSString
        var found: [TerminalArtifact] = []
        var covered: [NSRange] = []
        // `ls -l` rows: a directory's name is the last field.
        if line.hasPrefix("d"), line.count > 10, line.prefix(10).allSatisfy({ "drwxsStT-@+".contains($0) }),
           let name = line.split(separator: " ").last, name != ".", name != ".." {
            add(TerminalArtifact(reference: String(name) + "/", kind: .directory), to: &found)
            return found
        }
        for match in Self.url.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            var reference = ns.substring(with: match.range)
            while let last = reference.last, ".,;:".contains(last) { reference.removeLast() }
            covered.append(match.range)
            add(TerminalArtifact(reference: reference, kind: .link), to: &found)
        }
        for match in Self.path.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1)
            if covered.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let reference = ns.substring(with: range)
            let lineNumber = match.range(at: 2).location != NSNotFound ? Int(ns.substring(with: match.range(at: 2))) : nil
            guard let kind = Self.classify(reference) else { continue }
            add(TerminalArtifact(reference: reference, kind: kind, line: lineNumber), to: &found)
        }
        return found
    }

    // MARK: Logical lines

    /// The output stream breaks a line wherever the sender did: a grid replay
    /// or a shell that moves to the next row at the right margin turns one
    /// long path into two rows, which the stream scan reads as two
    /// references. The terminal's own screen knows better. Ghostty's text read
    /// joins rows it soft-wrapped, and a row that fills the whole width with
    /// no trailing space continues on the next row (`columns`).
    public static func logicalLines(in text: String, columns: Int?) -> [String] {
        let rows = text.components(separatedBy: CharacterSet.newlines)
        guard let columns, columns > 0 else { return rows }
        var lines: [String] = []
        var current: String?
        for (index, row) in rows.enumerated() {
            let joined = (current ?? "") + row
            let next = index + 1 < rows.count ? rows[index + 1] : ""
            if row.count == columns, continues(row, into: next) {
                current = joined
            } else {
                lines.append(joined)
                current = nil
            }
        }
        if let current { lines.append(current) }
        return lines
    }

    private static let referenceCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~@+%?=&#:"))

    /// A full row continues only through a reference: it ends, and the next
    /// row starts, with a path or URL character, and the row's last word is
    /// not a rule (`-----`, `=====`).
    private static func continues(_ row: String, into next: String) -> Bool {
        guard let last = row.unicodeScalars.last, let first = next.unicodeScalars.first,
              referenceCharacters.contains(last), referenceCharacters.contains(first) else { return false }
        let word = row.split(whereSeparator: \.isWhitespace).last ?? ""
        return Set(word).count > 1
    }

    /// Rescans the terminal's screen text (logical lines) and merges it with
    /// what the stream scan found: a reference the stream saw in pieces
    /// replaces its pieces (start, middle or end: a path over three rows has a
    /// middle piece) and takes the first piece's place; references that
    /// left the screen (history) stay. New ones go to the end.
    public mutating func reconcile(_ existing: [TerminalArtifact], screenText: String, columns: Int?) -> [TerminalArtifact] {
        var screen = ArtifactExtractor()
        var whole: [TerminalArtifact] = []
        for line in Self.logicalLines(in: screenText, columns: columns) where !line.isEmpty {
            whole += screen.scanLine(line)
        }
        let onScreen = Set(whole.map { Self.canonical($0.reference) })
        var result = existing
        for artifact in whole where !result.contains(where: { Self.canonical($0.reference) == Self.canonical(artifact.reference) }) {
            let pieces = result.filter { piece in
                !onScreen.contains(piece.reference)
                    && artifact.reference.contains(piece.reference)
            }
            var artifact = artifact
            if let first = pieces.min(by: { $0.order < $1.order }) {
                artifact.order = first.order
                let dropped = Set(pieces.map(\.reference))
                result.removeAll { dropped.contains($0.reference) }
                result.append(artifact)
            } else {
                artifact.order = count
                count += 1
                result.append(artifact)
            }
            seen.insert(Self.canonical(artifact.reference))
        }
        // A piece of a wrapped reference that is already listed whole (the
        // whole one was seen first, e.g. in the command line) goes too: the
        // screen never shows the piece on its own (R2-7).
        let wholes = result.map(\.reference).filter { onScreen.contains(Self.canonical($0)) }
        result.removeAll { piece in
            !onScreen.contains(Self.canonical(piece.reference))
                && wholes.contains { $0 != piece.reference && $0.count > piece.reference.count && $0.contains(piece.reference) }
        }
        // One entry per file: `/tmp/x` and `/private/tmp/x` are the same.
        var kept = Set<String>()
        result = result.sorted { $0.order < $1.order }.filter { kept.insert(Self.canonical($0.reference)).inserted }
        return result
    }

    /// Drops pieces of wrapped references anywhere in the list, scrollback
    /// included (R3-3): a reference that another one ends with, starting in
    /// the middle of a path component (`rivate/tmp/x` of `/private/tmp/x`,
    /// `1910.txt` of `/tmp/e2e-091910.txt`), or a slash path without an
    /// extension that another one starts with, ending mid-component (`/tm`).
    /// A whole relative path (`docs/a.md` of `/repo/docs/a.md`) is kept.
    public static func droppingFragments(_ list: [TerminalArtifact]) -> [TerminalArtifact] {
        var wholes: [String] = []
        for artifact in list where artifact.kind != .link {
            wholes.append(artifact.reference)
            let canonical = canonical(artifact.reference)
            if canonical != artifact.reference { wholes.append(canonical) } else if ["/tmp/", "/var/", "/etc/"].contains(where: { artifact.reference.hasPrefix($0) }) {
                wholes.append("/private" + artifact.reference)
            }
        }
        func isFragment(_ piece: TerminalArtifact) -> Bool {
            guard piece.kind != .link else { return false }
            let r = piece.reference
            for w in wholes where w.count > r.count && canonical(w) != canonical(r) {
                // An absolute path is only ever a piece of another absolute one.
                if r.hasPrefix("/"), !(w.hasPrefix("/") || w.hasPrefix("~")) { continue }
                if w.hasSuffix(r) {
                    let before = w[w.index(w.endIndex, offsetBy: -r.count - 1)]
                    if before != "/" { return true }
                }
                if w.hasPrefix(r), r.hasPrefix("/"), !(r.split(separator: "/").last ?? "").contains(".") {
                    let after = w[w.index(w.startIndex, offsetBy: r.count)]
                    if after != "/" { return true }
                }
            }
            return false
        }
        return list.filter { !isFragment($0) }
    }

    /// The key two references to the same file share: macOS's `/tmp`, `/var`
    /// and `/etc` are `/private/...` (R2-7).
    public static func canonical(_ reference: String) -> String {
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst("/private".count))
        }
        return reference
    }

    private mutating func add(_ artifact: TerminalArtifact, to found: inout [TerminalArtifact]) {
        guard seen.insert(Self.canonical(artifact.reference)).inserted else { return }
        var artifact = artifact
        artifact.order = count
        count += 1
        found.append(artifact)
    }

    /// Paths with a known extension, or slash paths with a letter in every
    /// component (directories and binaries). Versions, times and ratios fail both.
    public static func classify(_ reference: String) -> TerminalArtifact.Kind? {
        let trimmed = reference.hasSuffix("/") ? String(reference.dropLast()) : reference
        guard !trimmed.isEmpty, trimmed.contains(where: \.isLetter) else { return nil }
        let name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = String(name[name.index(after: dot)...])
            if let kind = TerminalArtifact.kind(forExtension: ext) { return kind }
            if ["Cargo.lock", "Makefile", "Dockerfile"].contains(name) { return .text }
        }
        if ["Makefile", "Dockerfile", "LICENSE"].contains(name) { return .text }
        let components = trimmed.split(separator: "/")
        guard components.count >= 2 || reference.hasSuffix("/") else { return nil }
        guard components.allSatisfy({ $0.contains(where: \.isLetter) }) else { return nil }
        if reference.hasSuffix("/") { return .directory }
        if name.contains(".") { return nil }
        return trimmed.contains("/bin/") || trimmed.contains("/release/") || trimmed.contains("/debug/") ? .binary : .directory
    }
}

extension TerminalArtifact {
    /// An SVG file drawn in a page of its own, centered and fitted to the screen (bare markup
    /// draws at its own size in the top-left corner).
    nonisolated static func fittedSVG(_ svg: String) -> String {
        "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<style>html,body{margin:0;height:100%;}body{display:flex;align-items:center;justify-content:center;}"
            + "svg{width:100%;height:100%;max-width:100vw;max-height:100vh;}</style></head><body>"
            + svg + "</body></html>"
    }
}
