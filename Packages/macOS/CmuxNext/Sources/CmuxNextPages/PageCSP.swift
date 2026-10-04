public import Foundation

/// The one per-page Content Security Policy mechanism (decided 2026-10-04 for the agent page's
/// loopback connections and frames and the diff page's WebAssembly and provider connection). The
/// scheme handler sends it as the response header, the only CSP a page gets. Every page starts
/// strict: no network, no frames, inline script and style only; a first-party page may add
/// `connect-src` and `frame-src` sources and the one script keyword `'wasm-unsafe-eval'`. App pages
/// (``PageDescriptor/appPage(id:resource:namespaces:)``) always get the strict policy.
public nonisolated struct PageCSP: Sendable, Hashable {
    /// `connect-src` sources (`ws://127.0.0.1:*`, the page's own provider endpoint).
    public var connect: [String]
    /// `frame-src` sources (loopback previews).
    public var frame: [String]
    /// Extra `script-src` keywords; only ``allowedScriptKeywords`` are kept.
    public var script: [String]

    public static let allowedScriptKeywords: Set<String> = ["'wasm-unsafe-eval'"]
    public static let strict = PageCSP()

    public init(connect: [String] = [], frame: [String] = [], script: [String] = []) {
        self.connect = connect
        self.frame = frame
        self.script = script
    }

    static let base: [(String, [String])] = [
        ("default-src", ["'none'"]), ("script-src", ["'self'", "'unsafe-inline'"]),
        ("style-src", ["'self'", "'unsafe-inline'"]), ("img-src", ["'self'", "data:"]), ("font-src", ["'self'", "data:"]),
    ]

    /// The header value. A source with a character that could end or split a directive is dropped.
    public var header: String {
        func clean(_ sources: [String]) -> [String] {
            sources.filter { !$0.isEmpty && !$0.contains(where: { $0 == ";" || $0 == "," || $0.isWhitespace }) }
        }
        var directives = Self.base
        let keywords = script.filter(Self.allowedScriptKeywords.contains)
        if !keywords.isEmpty { directives[1].1 += keywords }
        let connect = clean(connect)
        if !connect.isEmpty { directives.append(("connect-src", connect)) }
        let frame = clean(frame)
        if !frame.isEmpty { directives.append(("frame-src", frame)) }
        return directives.map { "\($0.0) \($0.1.joined(separator: " "))" }.joined(separator: "; ")
    }
}
