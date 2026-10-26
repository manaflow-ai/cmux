#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `terminals` facet (p15-oracle-044, schemas/oracle/snapshot-v1.schema.json `terminals`): every local
/// terminal with its view's attach state, the PTY grid, the shell title and cwd the daemon reports, the exit code of
/// an ended one, and a hash of the last 24 rows of the screen its daemon holds. The host gives the screen as the
/// daemon's VT state (`read-screen`), never a Ghostty surface: two builds that hold the same terminal give the same
/// facet whatever their views draw. Chromium's web tests compare a page the same way when it asks for a text dump:
/// the document's text, not the pixels (content/web_test/renderer/test_runner.cc, `dumpAsText`).
///
/// A background facet: the host's one main-actor hop reads the daemon mirror's values (``Terminal``); the attach
/// state and every screen are read off the main actor, the screens at once. No private text: the title and the rows
/// go in as `sha256:<hex>` after the path rewrite (``PathRewrite``).
public struct OracleTerminalsFacet: OracleFacetProvider {
    /// The schema's `attach` values.
    public enum Attach: String, Sendable {
        /// The view's attach link is live.
        case attached
        /// No view attaches the terminal: no window mounts it, or its link is gone.
        case detached
        /// The view opens or reopens its link.
        case attaching
        /// The terminal's process ended.
        case dead
    }

    /// One terminal as the host's main-actor hop captures it: the daemon mirror's values, and the two reads that
    /// run off the main actor.
    public struct Terminal: Sendable {
        /// The public terminal id (`term_…`), else the daemon's terminal id.
        public var terminal: String
        public var tab: String?
        /// The PTY grid the daemon reports; 0 before its first report.
        public var cols: Int
        public var rows: Int
        /// The raw shell title (OSC 0/2).
        public var title: String
        public var cwd: String?
        /// The daemon reports the terminal's process ended.
        public var ended: Bool
        public var exitCode: Int?
        /// The attach state of the view that shows it; nil when no view is made.
        public var attach: (@Sendable () -> Attach)?
        /// The text of the daemon's screen, one line per row.
        public var screen: @Sendable () async throws -> String

        public init(terminal: String, tab: String?, cols: Int, rows: Int, title: String, cwd: String?, ended: Bool,
                    exitCode: Int?, attach: (@Sendable () -> Attach)?, screen: @escaping @Sendable () async throws -> String) {
            self.terminal = terminal
            self.tab = tab
            self.cols = cols
            self.rows = rows
            self.title = title
            self.cwd = cwd
            self.ended = ended
            self.exitCode = exitCode
            self.attach = attach
            self.screen = screen
        }
    }

    /// What a hashed text field holds in place of the run's own paths: the case root becomes `$ROOT`, the hermetic
    /// home `$HOME`, as scripts/cmux-next/oracle/normalize.py rewrites the raw path fields (schemas/oracle/README.md,
    /// `x-oracle-rewrite`). A hash cannot be rewritten after the fact, so the capture rewrites first.
    public struct PathRewrite: Sendable, Hashable {
        public struct Entry: Sendable, Hashable {
            public var prefix: String
            public var token: String
        }

        /// The case root the runner launched the app under, read once at the composition root: its paths separated
        /// by `:`, each alias a shell may report too (`/tmp/o/…` and `/private/tmp/o/…` on macOS), as the runner gives
        /// normalize.py several values per token.
        public static let rootVariable = "CMUX_ORACLE_ROOT"

        /// Longest prefix first: a root inside the home is `$ROOT`.
        public private(set) var entries: [Entry]

        public init(root: [String], home: [String]) {
            var entries: [Entry] = []
            for (token, prefixes) in [("$ROOT", root), ("$HOME", home)] {
                for prefix in prefixes {
                    var trimmed = prefix
                    while trimmed.hasSuffix("/") { trimmed.removeLast() }
                    guard !trimmed.isEmpty, !entries.contains(where: { $0.prefix == trimmed }) else { continue }
                    entries.append(Entry(prefix: trimmed, token: token))
                }
            }
            self.entries = entries.sorted { $0.prefix.count != $1.prefix.count ? $0.prefix.count > $1.prefix.count : $0.prefix < $1.prefix }
        }

        /// `CMUX_ORACLE_ROOT` and `HOME` of the app's launch environment.
        public init(environment: [String: String]) {
            let root = environment[Self.rootVariable].map { $0.split(separator: ":").map(String.init) } ?? []
            self.init(root: root, home: environment["HOME"].map { [$0] } ?? [])
        }

        /// `text` with every prefix that stands as a whole path (not inside a longer name) replaced by its token.
        public func apply(_ text: String) -> String {
            var text = text
            for entry in entries {
                var out = ""
                var rest = text[...]
                while let found = rest.firstRange(of: entry.prefix) {
                    let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
                    let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
                    out.append(contentsOf: text[rest.startIndex..<found.lowerBound])
                    out.append(contentsOf: Self.continuesName(before) || Self.continuesName(after) ? String(text[found]) : entry.token)
                    rest = text[found.upperBound...]
                }
                out.append(contentsOf: rest)
                text = out
            }
            return text
        }

        /// A character a name goes on with (normalize.py `[A-Za-z0-9._~-]`): a prefix next to one is part of a
        /// longer name.
        private static func continuesName(_ character: Character?) -> Bool {
            guard let character, character.isASCII else { return false }
            return character.isLetter || character.isNumber || "._~-".contains(character)
        }
    }

    /// The rows the facet hashes: a standard terminal's height.
    public static let hashedRows = 24

    public var facet: OracleFacet { .terminals }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - rewrite: The run's paths, rewritten in the title and the rows before they are hashed.
    ///   - hash: `sha256:<hex>` of a text.
    ///   - terminals: The terminals now, read in one main-actor hop; daemon mirror values only.
    public init(rewrite: PathRewrite, hash: @escaping @Sendable (String) -> String,
                terminals: @escaping @MainActor @Sendable () throws(OracleFacetError) -> [Terminal]) {
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            let list = try await terminals()
            return try await Self.read(list, rewrite: rewrite, hash: hash)
        }
    }

    /// The facet's value: every terminal's screen read at once, off the main actor.
    @concurrent
    static func read(_ terminals: [Terminal], rewrite: PathRewrite,
                     hash: @escaping @Sendable (String) -> String) async throws(OracleFacetError) -> OracleValue {
        let screens = await withTaskGroup(of: (Int, Result<String, any Error>).self) { group in
            for (index, terminal) in terminals.enumerated() {
                group.addTask {
                    let screen: Result<String, any Error>
                    do { screen = .success(try await terminal.screen()) } catch { screen = .failure(error) }
                    return (index, screen)
                }
            }
            var screens: [Int: Result<String, any Error>] = [:]
            for await (index, screen) in group { screens[index] = screen }
            return screens
        }
        var list: [OracleValue] = []
        for (index, terminal) in terminals.enumerated() {
            switch screens[index] {
            case .success(let screen)?:
                list.append(value(of: terminal, screen: screen, rewrite: rewrite, hash: hash))
            case .failure(let error)?:
                throw OracleFacetError("terminal \(terminal.terminal): read-screen failed: \(error)")
            case nil:
                throw OracleFacetError("terminal \(terminal.terminal): read-screen gave no answer")
            }
        }
        return ["list": .array(list)]
    }

    /// The schema's object for one terminal.
    static func value(of terminal: Terminal, screen: String, rewrite: PathRewrite, hash: (String) -> String) -> OracleValue {
        let attach: Attach = terminal.ended ? .dead : terminal.attach?() ?? .detached
        return [
            "terminal": .string(terminal.terminal),
            "tab": terminal.tab.map(OracleValue.string) ?? .null,
            "attach": .string(attach.rawValue),
            "cols": OracleValue(terminal.cols),
            "rows": OracleValue(terminal.rows),
            "title": .string(hash(rewrite.apply(terminal.title))),
            "cwd": terminal.cwd.map(OracleValue.string) ?? .null,
            "last24Sha256": .string(hash(rewrite.apply(lastRows(of: screen)))),
            "exitCode": terminal.exitCode.map { OracleValue($0) } ?? .null,
        ]
    }

    /// The last ``hashedRows`` rows of a screen's text (schema: "the last 24 rows of /text split on newline").
    public static func lastRows(of screen: String) -> String {
        screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(hashedRows).joined(separator: "\n")
    }
}
#endif
