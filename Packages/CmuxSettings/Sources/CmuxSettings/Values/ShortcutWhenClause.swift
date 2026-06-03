import Foundation

/// A keyboard-shortcut focus atom — the boolean context keys a ``ShortcutWhenClause``
/// is evaluated against. Modeled on VS Code's `when`-clause context keys, scoped to
/// the focus dimensions cmux tracks.
public enum ShortcutFocusAtom: String, CaseIterable, Sendable {
    /// The right sidebar (vault/files/find/feed/dock) owns focus.
    case sidebarFocus
    /// A browser panel owns focus.
    case browserFocus
    /// A markdown preview viewer owns focus.
    case markdownFocus
    /// A terminal owns focus — i.e. none of the other focus atoms hold.
    case terminalFocus
}

/// A snapshot of the focus dimensions a ``ShortcutWhenClause`` evaluates against.
///
/// `terminalFocus` is derived: a terminal owns focus exactly when no browser,
/// markdown, or sidebar focus is present.
public struct ShortcutFocusState: Equatable, Sendable {
    /// Whether a browser panel owns focus for the shortcut event.
    public var browser: Bool
    /// Whether a markdown preview owns focus for the shortcut event.
    public var markdown: Bool
    /// Whether the right sidebar owns focus for the shortcut event.
    public var sidebar: Bool

    /// Creates a focus snapshot from the app target's current shortcut focus dimensions.
    ///
    /// - Parameters:
    ///   - browser: Whether a browser panel owns focus for the shortcut event.
    ///   - markdown: Whether a markdown preview owns focus for the shortcut event.
    ///   - sidebar: Whether the right sidebar owns focus for the shortcut event.
    public init(browser: Bool, markdown: Bool, sidebar: Bool) {
        self.browser = browser
        self.markdown = markdown
        self.sidebar = sidebar
    }

    /// Whether a terminal owns focus, derived from the absence of browser, markdown, and sidebar focus.
    public var terminal: Bool { !browser && !markdown && !sidebar }

    /// Returns the boolean value of a supported focus atom in this snapshot.
    ///
    /// - Parameter atom: The focus atom to read.
    /// - Returns: The atom's value in this focus state.
    public func value(of atom: ShortcutFocusAtom) -> Bool {
        switch atom {
        case .sidebarFocus: return sidebar
        case .browserFocus: return browser
        case .markdownFocus: return markdown
        case .terminalFocus: return terminal
        }
    }

    /// The set of focus states the runtime can actually produce.
    ///
    /// `markdownFocus` never co-occurs with `browserFocus` (the focus
    /// computation only treats a markdown panel as focused when no browser
    /// panel owns the event), so those combinations are excluded. Everything
    /// else is treated as realizable, which keeps conflict detection
    /// conservative (it would rather flag a possible collision than miss one).
    public static let realizableStates: [ShortcutFocusState] = {
        var states: [ShortcutFocusState] = []
        for browser in [false, true] {
            for markdown in [false, true] {
                for sidebar in [false, true] {
                    if browser && markdown { continue }
                    states.append(ShortcutFocusState(browser: browser, markdown: markdown, sidebar: sidebar))
                }
            }
        }
        return states
    }()
}

/// A parsed `when` predicate that gates a keyboard shortcut by focus context,
/// modeled on VS Code's `when` clauses.
///
/// Combine ``ShortcutFocusAtom`` keys with `!` (not), `&&` (and), `||` (or), and
/// parentheses. `||` binds loosest, then `&&`, then `!`. An empty/whitespace
/// clause parses to ``always``.
///
/// ```swift
/// ShortcutWhenClause.parse("!sidebarFocus")            // workspace digits everywhere but the sidebar
/// ShortcutWhenClause.parse("terminalFocus || browserFocus")
/// ```
public indirect enum ShortcutWhenClause: Equatable, Sendable {
    /// Always satisfied (the clause imposes no focus restriction).
    case always
    /// Satisfied when the given focus atom holds.
    case atom(ShortcutFocusAtom)
    /// Satisfied when the wrapped clause is not.
    case not(ShortcutWhenClause)
    /// Satisfied when both clauses are.
    case and(ShortcutWhenClause, ShortcutWhenClause)
    /// Satisfied when either clause is.
    case or(ShortcutWhenClause, ShortcutWhenClause)

    /// Evaluates the clause against a focus snapshot.
    public func evaluate(_ state: ShortcutFocusState) -> Bool {
        switch self {
        case .always:
            return true
        case let .atom(atom):
            return state.value(of: atom)
        case let .not(clause):
            return !clause.evaluate(state)
        case let .and(lhs, rhs):
            return lhs.evaluate(state) && rhs.evaluate(state)
        case let .or(lhs, rhs):
            return lhs.evaluate(state) || rhs.evaluate(state)
        }
    }

    /// Whether two clauses can be satisfied by the same realizable focus state.
    ///
    /// Used by conflict detection: two shortcuts on the same keystroke truly
    /// collide only if some focus state activates both. Non-overlapping `when`
    /// clauses (e.g. `sidebarFocus` and `!sidebarFocus`) let the same keystroke
    /// drive different actions in different contexts.
    public static func canCoexist(_ lhs: ShortcutWhenClause, _ rhs: ShortcutWhenClause) -> Bool {
        ShortcutFocusState.realizableStates.contains { state in
            lhs.evaluate(state) && rhs.evaluate(state)
        }
    }

    /// Parses a `when` expression, returning `nil` on malformed input so callers
    /// can fall back to a default context rather than silently mis-gating. An
    /// empty or whitespace-only clause imposes no restriction and parses to
    /// ``always``.
    public static func parse(_ raw: String) -> ShortcutWhenClause? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .always
        }
        var parser = Parser(raw)
        guard let clause = parser.parseExpression() else { return nil }
        guard parser.isAtEnd else { return nil }
        return clause
    }
}

extension ShortcutWhenClause {
    /// Recursive-descent parser for the `when` mini-language.
    ///
    /// Grammar (loosest to tightest binding):
    /// ```
    /// expression := or
    /// or         := and ( "||" and )*
    /// and        := unary ( "&&" unary )*
    /// unary      := "!" unary | primary
    /// primary    := "(" expression ")" | atom
    /// ```
    private struct Parser {
        private let tokens: [Token]
        private var index = 0

        init(_ raw: String) {
            tokens = Token.tokenize(raw)
        }

        var isAtEnd: Bool { index >= tokens.count }

        private func peek() -> Token? { index < tokens.count ? tokens[index] : nil }

        private mutating func advance() -> Token? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        mutating func parseExpression() -> ShortcutWhenClause? {
            parseOr()
        }

        private mutating func parseOr() -> ShortcutWhenClause? {
            guard var lhs = parseAnd() else { return nil }
            while peek() == .or {
                _ = advance()
                guard let rhs = parseAnd() else { return nil }
                lhs = .or(lhs, rhs)
            }
            return lhs
        }

        private mutating func parseAnd() -> ShortcutWhenClause? {
            guard var lhs = parseUnary() else { return nil }
            while peek() == .and {
                _ = advance()
                guard let rhs = parseUnary() else { return nil }
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        private mutating func parseUnary() -> ShortcutWhenClause? {
            if peek() == .not {
                _ = advance()
                guard let operand = parseUnary() else { return nil }
                return .not(operand)
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> ShortcutWhenClause? {
            switch advance() {
            case .lparen:
                guard let inner = parseExpression(), peek() == .rparen else { return nil }
                _ = advance()
                return inner
            case let .identifier(name):
                guard let atom = ShortcutFocusAtom(rawValue: name) else { return nil }
                return .atom(atom)
            default:
                return nil
            }
        }
    }

    private enum Token: Equatable {
        case not
        case and
        case or
        case lparen
        case rparen
        case identifier(String)

        static func tokenize(_ raw: String) -> [Token] {
            var tokens: [Token] = []
            let scalars = Array(raw.unicodeScalars)
            var i = 0
            func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
                CharacterSet.alphanumerics.contains(s) || s == "_"
            }
            while i < scalars.count {
                let scalar = scalars[i]
                switch scalar {
                case " ", "\t", "\n", "\r":
                    i += 1
                case "!":
                    tokens.append(.not)
                    i += 1
                case "(":
                    tokens.append(.lparen)
                    i += 1
                case ")":
                    tokens.append(.rparen)
                    i += 1
                case "&":
                    i += 1
                    if i < scalars.count && scalars[i] == "&" { i += 1 }
                    tokens.append(.and)
                case "|":
                    i += 1
                    if i < scalars.count && scalars[i] == "|" { i += 1 }
                    tokens.append(.or)
                default:
                    if isIdentifierScalar(scalar) {
                        var name = ""
                        while i < scalars.count && isIdentifierScalar(scalars[i]) {
                            name.unicodeScalars.append(scalars[i])
                            i += 1
                        }
                        tokens.append(.identifier(name))
                    } else {
                        tokens.append(.identifier("\u{0}invalid"))
                        i += 1
                    }
                }
            }
            return tokens
        }
    }
}
