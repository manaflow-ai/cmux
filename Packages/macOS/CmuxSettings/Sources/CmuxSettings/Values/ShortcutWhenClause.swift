import Foundation

/// A parsed `when` predicate that gates a keyboard shortcut by context, modeled
/// on VS Code's `when` clauses.
///
/// A clause combines context keys with boolean operators and comparisons:
///
/// - **Boolean keys** are tested bare: the focus atoms (``ShortcutFocusAtom``) and
///   other boolean keys from ``ShortcutContextKnownKey`` such as
///   `commandPaletteVisible`. An unknown bare key is a valid clause that evaluates
///   to `false` (VS Code semantics).
/// - **Boolean operators**: `!` (not), `&&` (and), `||` (or), with parentheses.
///   `||` binds loosest, then `&&`, then comparisons, then `!`.
/// - **Comparisons** against typed keys: `==`, `!=`, `=~` (regex), `<`, `<=`,
///   `>`, `>=`, and `in [a, b]`.
/// - **Boolean literals**: a bare `true` parses to ``always`` and `false` to its
///   negation, and boolean-literal equality folds onto the key itself —
///   `key == true` ≡ `key`, `key == false` ≡ `!key` (so `key == false` also
///   matches when the key is unset), mirroring VS Code's
///   `ContextKeyExpr.has`/`not` normalization.
///
/// An empty/whitespace clause parses to ``always``.
///
/// ```swift
/// ShortcutWhenClause.parse("!sidebarFocus")                  // everywhere but the sidebar
/// ShortcutWhenClause.parse("terminalFocus || browserFocus")
/// ShortcutWhenClause.parse("commandPaletteVisible && paneCount > 1")
/// ShortcutWhenClause.parse("sidebarMode == 'find'")
/// ```
public indirect enum ShortcutWhenClause: Equatable, Sendable {
    /// Always satisfied (the clause imposes no restriction).
    case always
    /// Satisfied when the given focus atom holds.
    case atom(ShortcutFocusAtom)
    /// Satisfied when the named boolean context key is `true`.
    ///
    /// Used for non-focus boolean keys and unknown keys; an absent or non-boolean
    /// key reads as `false`.
    case key(String)
    /// Satisfied when the named context key compares as described against the operand.
    case compare(key: String, op: ShortcutComparisonOperator, operand: ShortcutContextOperand)
    /// Satisfied when the wrapped clause is not.
    case not(ShortcutWhenClause)
    /// Satisfied when both clauses are.
    case and(ShortcutWhenClause, ShortcutWhenClause)
    /// Satisfied when either clause is.
    case or(ShortcutWhenClause, ShortcutWhenClause)

    /// Evaluates the clause against a focus snapshot.
    ///
    /// Backwards-compatible overload for focus-only callers; lifts the focus state
    /// into a ``ShortcutContext`` via ``ShortcutFocusState/context`` and evaluates
    /// against that.
    ///
    /// - Parameter state: The focus snapshot for the shortcut event.
    /// - Returns: Whether the clause is satisfied.
    public func evaluate(_ state: ShortcutFocusState) -> Bool {
        evaluate(state.context)
    }

    /// Evaluates the clause against a full context snapshot.
    ///
    /// - Parameter context: The context keys for the shortcut event.
    /// - Returns: Whether the clause is satisfied.
    public func evaluate(_ context: ShortcutContext) -> Bool {
        switch self {
        case .always:
            return true
        case let .atom(atom):
            return context.bool(atom.rawValue)
        case let .key(name):
            return context.bool(name)
        case let .compare(key, op, operand):
            return ShortcutWhenClause.evaluateComparison(key: key, op: op, operand: operand, context: context)
        case let .not(clause):
            return !clause.evaluate(context)
        case let .and(lhs, rhs):
            return lhs.evaluate(context) && rhs.evaluate(context)
        case let .or(lhs, rhs):
            return lhs.evaluate(context) || rhs.evaluate(context)
        }
    }

    /// Whether two clauses can be satisfied by the same realizable context.
    ///
    /// Used by conflict detection: two shortcuts on the same keystroke truly
    /// collide only if some context activates both. Non-overlapping clauses (e.g.
    /// `sidebarFocus` and `!sidebarFocus`) let the same keystroke drive different
    /// actions in different contexts.
    ///
    /// Focus atoms are enumerated over ``ShortcutFocusState/realizableStates``
    /// (preserving the rule that browser and markdown focus never co-occur, and
    /// keeping `terminalFocus` derived); every other distinct key/comparison term
    /// is treated as an independent free boolean. This is **sound** for conflict
    /// detection — it never reports two clauses as non-coexisting when they can in
    /// fact both hold — and is **exact** for focus-only clauses. Distinct
    /// comparisons on the same key (e.g. `paneCount == 1` and `paneCount == 2`) are
    /// modeled independently, which can over-report coexistence (the harmless
    /// direction). Beyond a small variable cap the result is a conservative `true`.
    public static func canCoexist(_ lhs: ShortcutWhenClause, _ rhs: ShortcutWhenClause) -> Bool {
        var usesFocus = false
        var freeTerms: Set<String> = []
        lhs.collectFreeTerms(usesFocus: &usesFocus, into: &freeTerms)
        rhs.collectFreeTerms(usesFocus: &usesFocus, into: &freeTerms)

        let terms = Array(freeTerms)
        // Bound the opaque free-variable enumeration; beyond the cap, conservatively
        // assume the clauses can coexist (never hides a real conflict).
        if terms.count > 12 { return true }

        let focusStates = usesFocus
            ? ShortcutFocusState.realizableStates
            : [ShortcutFocusState(browser: false, markdown: false, sidebar: false)]
        for state in focusStates {
            for mask in 0..<(1 << terms.count) {
                var assignment: [String: Bool] = [:]
                for (index, term) in terms.enumerated() {
                    assignment[term] = (mask & (1 << index)) != 0
                }
                if lhs.satisfies(focus: state, freeTerms: assignment),
                   rhs.satisfies(focus: state, freeTerms: assignment) {
                    return true
                }
            }
        }
        return false
    }

    /// Whether two bindings on the same keystroke genuinely collide: their
    /// effective clauses can hold in the same context **and** router priority
    /// cannot deterministically pick a winner for the overlap.
    ///
    /// `hasPriority` marks a side the app's key router consumes before general
    /// shortcut matching whenever its clause holds (see
    /// ``ShortcutAction/hasPriorityShortcutRouting`` — today the right-sidebar
    /// mode shortcuts). Such a pair coexists when the non-prioritized side can
    /// still fire somewhere outside the winner's context
    /// (`canCoexist(loser, !winner)`): the winner owns every overlapping state
    /// and the loser owns the rest — the same most-specific-wins resolution VS
    /// Code applies to `when` clauses. The shipped defaults rely on this:
    /// Select Surface `⌃1…9` coexists with the sidebar's `⌃1…5`, which win only
    /// while the sidebar is focused.
    ///
    /// A loser with no states of its own (its clause implies the winner's) would
    /// never fire, so that pair still reports as a collision rather than letting
    /// the user save a dead binding. Two prioritized sides (or two ordinary
    /// sides) fall back to plain ``canCoexist(_:_:)`` overlap.
    public static func bindingsCollide(
        _ lhs: ShortcutWhenClause,
        lhsHasPriority: Bool,
        _ rhs: ShortcutWhenClause,
        rhsHasPriority: Bool
    ) -> Bool {
        guard canCoexist(lhs, rhs) else { return false }
        guard lhsHasPriority != rhsHasPriority else { return true }
        let winner = lhsHasPriority ? lhs : rhs
        let loser = lhsHasPriority ? rhs : lhs
        return !canCoexist(loser, .not(winner))
    }

    /// Parses a `when` expression, returning `nil` on malformed input so callers
    /// can fall back to a default context rather than silently mis-gating. An empty
    /// or whitespace-only clause imposes no restriction and parses to ``always``.
    ///
    /// An unknown bare key parses to ``key(_:)`` (a valid, always-false clause),
    /// matching VS Code's treatment of undefined context keys.
    ///
    /// - Parameter raw: The predicate source from `shortcuts.when` in cmux.json.
    /// - Returns: The parsed clause, or `nil` when the input is malformed.
    public static func parse(_ raw: String) -> ShortcutWhenClause? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .always
        }
        var parser = Parser(raw)
        guard let clause = parser.parseExpression() else { return nil }
        guard parser.isAtEnd else { return nil }
        return clause
    }

    // MARK: - Evaluation helpers

    private static func evaluateComparison(
        key: String,
        op: ShortcutComparisonOperator,
        operand: ShortcutContextOperand,
        context: ShortcutContext
    ) -> Bool {
        switch op {
        case .equals:
            return comparisonEquals(key: key, operand: operand, context: context)
        case .notEquals:
            return !comparisonEquals(key: key, operand: operand, context: context)
        case .matches:
            guard case let .regex(regex) = operand, let value = context.string(key) else { return false }
            return regex.matches(value)
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard case let .int(rhs) = operand, let lhs = context.int(key) else { return false }
            switch op {
            case .lessThan: return lhs < rhs
            case .lessThanOrEqual: return lhs <= rhs
            case .greaterThan: return lhs > rhs
            case .greaterThanOrEqual: return lhs >= rhs
            default: return false
            }
        case .inList:
            guard case let .list(items) = operand else { return false }
            return items.contains { comparisonEquals(key: key, operand: $0, context: context) }
        }
    }

    private static func comparisonEquals(
        key: String,
        operand: ShortcutContextOperand,
        context: ShortcutContext
    ) -> Bool {
        switch operand {
        case let .string(expected):
            return context.string(key) == expected
        case let .int(expected):
            return context.int(key) == expected
        case .regex, .list:
            return false
        }
    }

    // MARK: - Conflict-detection helpers

    /// The bare context key when this clause is a single ``atom(_:)`` or
    /// ``key(_:)``; otherwise `nil`. Used as the left-hand side of a comparison.
    private var barewordKey: String? {
        switch self {
        case let .atom(atom): return atom.rawValue
        case let .key(name): return name
        default: return nil
        }
    }

    /// Collects the abstract boolean variables this clause references for
    /// conflict-detection enumeration: focus atoms set `usesFocus`, while every
    /// distinct `.key`/`.compare` term contributes a canonical id.
    private func collectFreeTerms(usesFocus: inout Bool, into terms: inout Set<String>) {
        switch self {
        case .always:
            break
        case .atom:
            usesFocus = true
        case let .key(name):
            terms.insert("key:\(name)")
        case let .compare(key, op, operand):
            terms.insert(ShortcutWhenClause.comparisonTermID(key: key, op: op, operand: operand))
        case let .not(clause):
            clause.collectFreeTerms(usesFocus: &usesFocus, into: &terms)
        case let .and(lhs, rhs), let .or(lhs, rhs):
            lhs.collectFreeTerms(usesFocus: &usesFocus, into: &terms)
            rhs.collectFreeTerms(usesFocus: &usesFocus, into: &terms)
        }
    }

    /// Evaluates the clause for conflict detection against a focus state plus an
    /// assignment of every non-focus term to a boolean.
    private func satisfies(focus: ShortcutFocusState, freeTerms: [String: Bool]) -> Bool {
        switch self {
        case .always:
            return true
        case let .atom(atom):
            return focus.value(of: atom)
        case let .key(name):
            return freeTerms["key:\(name)"] ?? false
        case let .compare(key, op, operand):
            return freeTerms[ShortcutWhenClause.comparisonTermID(key: key, op: op, operand: operand)] ?? false
        case let .not(clause):
            return !clause.satisfies(focus: focus, freeTerms: freeTerms)
        case let .and(lhs, rhs):
            return lhs.satisfies(focus: focus, freeTerms: freeTerms)
                && rhs.satisfies(focus: focus, freeTerms: freeTerms)
        case let .or(lhs, rhs):
            return lhs.satisfies(focus: focus, freeTerms: freeTerms)
                || rhs.satisfies(focus: focus, freeTerms: freeTerms)
        }
    }

    /// A stable identifier for a comparison term so the same comparison appearing
    /// in both clauses maps to the same free variable during enumeration.
    private static func comparisonTermID(
        key: String,
        op: ShortcutComparisonOperator,
        operand: ShortcutContextOperand
    ) -> String {
        "cmp:\(key)\(op.rawValue)\(operandID(operand))"
    }

    private static func operandID(_ operand: ShortcutContextOperand) -> String {
        switch operand {
        case let .string(value): return "s'\(value)'"
        case let .int(value): return "i\(value)"
        case let .regex(regex): return "r/\(regex.pattern)/"
        case let .list(items): return "[\(items.map(operandID).joined(separator: ","))]"
        }
    }
}

extension ShortcutWhenClause {
    /// Recursive-descent parser for the `when` mini-language.
    ///
    /// Grammar (loosest to tightest binding):
    /// ```
    /// expression := or
    /// or         := and        ( "||" and )*
    /// and        := comparison ( "&&" comparison )*
    /// comparison := unary ( compareOp operand )?      // LHS must be a bare key; at most one operator
    /// unary      := "!" unary | primary
    /// primary    := "(" expression ")" | identifier
    /// operand    := number | "'"string"'" | identifier | /regex/ | "[" (literal ("," literal)*)? "]"
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
            guard var lhs = parseComparison() else { return nil }
            while peek() == .and {
                _ = advance()
                guard let rhs = parseComparison() else { return nil }
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        private mutating func parseComparison() -> ShortcutWhenClause? {
            guard let lhs = parseUnary() else { return nil }
            guard let op = comparisonOperator(for: peek()) else { return lhs }
            // The left-hand side of a comparison must be a bare context key.
            guard let key = lhs.barewordKey else { return nil }
            _ = advance() // consume the comparison operator
            guard let operand = parseOperand(for: op) else { return nil }
            // Boolean-literal equality folds onto the key itself, as in VS Code:
            // `k == true` ≡ `k`, `k == false` ≡ `!k`, inverted for `!=`. Keeping
            // the original `.atom`/`.key` node (rather than a `.compare`) lets
            // conflict detection reason about it exactly.
            if op == .equals || op == .notEquals,
               case let .string(raw) = operand,
               raw == "true" || raw == "false" {
                let wantsKeyTrue = (raw == "true") == (op == .equals)
                return wantsKeyTrue ? lhs : .not(lhs)
            }
            return .compare(key: key, op: op, operand: operand)
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
                // VS Code accepts bare boolean literals: `true` is the
                // unrestricted clause, `false` never matches.
                if name == "true" { return .always }
                if name == "false" { return .not(.always) }
                if let atom = ShortcutFocusAtom(rawValue: name) {
                    return .atom(atom)
                }
                return .key(name)
            default:
                return nil
            }
        }

        private func comparisonOperator(for token: Token?) -> ShortcutComparisonOperator? {
            switch token {
            case .eq: return .equals
            case .neq: return .notEquals
            case .matchOp: return .matches
            case .lt: return .lessThan
            case .lte: return .lessThanOrEqual
            case .gt: return .greaterThan
            case .gte: return .greaterThanOrEqual
            case .identifier("in"): return .inList
            default: return nil
            }
        }

        private mutating func parseOperand(for op: ShortcutComparisonOperator) -> ShortcutContextOperand? {
            switch op {
            case .matches:
                switch advance() {
                case let .regex(regex): return .regex(regex)
                default: return nil
                }
            case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
                switch advance() {
                case let .number(value): return .int(value)
                default: return nil
                }
            case .inList:
                return parseListOperand()
            case .equals, .notEquals:
                switch advance() {
                case let .number(value): return .int(value)
                case let .string(value): return .string(value)
                case let .identifier(name): return .string(name)
                default: return nil
                }
            }
        }

        private mutating func parseListOperand() -> ShortcutContextOperand? {
            switch advance() {
            case .lbracket: break
            default: return nil
            }
            var items: [ShortcutContextOperand] = []
            if peek() == .rbracket {
                _ = advance()
                return .list(items)
            }
            while true {
                switch advance() {
                case let .number(value): items.append(.int(value))
                case let .string(value): items.append(.string(value))
                case let .identifier(name): items.append(.string(name))
                default: return nil
                }
                switch advance() {
                case .comma: continue
                case .rbracket: return .list(items)
                default: return nil
                }
            }
        }
    }

    private enum Token: Equatable {
        case not
        case and
        case or
        case lparen
        case rparen
        case lbracket
        case rbracket
        case comma
        case eq
        case neq
        case matchOp
        case lt
        case lte
        case gt
        case gte
        case identifier(String)
        case number(Int)
        case string(String)
        case regex(ShortcutRegex)
        case invalid

        static func tokenize(_ raw: String) -> [Token] {
            var tokens: [Token] = []
            let scalars = Array(raw.unicodeScalars)
            var i = 0
            func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
                CharacterSet.alphanumerics.contains(s) || s == "_"
            }
            func isDigit(_ s: Unicode.Scalar) -> Bool {
                CharacterSet.decimalDigits.contains(s)
            }
            while i < scalars.count {
                let scalar = scalars[i]
                switch scalar {
                case " ", "\t", "\n", "\r":
                    i += 1
                case "(":
                    tokens.append(.lparen); i += 1
                case ")":
                    tokens.append(.rparen); i += 1
                case "[":
                    tokens.append(.lbracket); i += 1
                case "]":
                    tokens.append(.rbracket); i += 1
                case ",":
                    tokens.append(.comma); i += 1
                case "!":
                    i += 1
                    if i < scalars.count && scalars[i] == "=" {
                        i += 1
                        tokens.append(.neq)
                    } else {
                        tokens.append(.not)
                    }
                case "=":
                    i += 1
                    if i < scalars.count && scalars[i] == "=" {
                        i += 1
                        tokens.append(.eq)
                    } else if i < scalars.count && scalars[i] == "~" {
                        i += 1
                        tokens.append(.matchOp)
                    } else {
                        tokens.append(.invalid)
                    }
                case "<":
                    i += 1
                    if i < scalars.count && scalars[i] == "=" {
                        i += 1
                        tokens.append(.lte)
                    } else {
                        tokens.append(.lt)
                    }
                case ">":
                    i += 1
                    if i < scalars.count && scalars[i] == "=" {
                        i += 1
                        tokens.append(.gte)
                    } else {
                        tokens.append(.gt)
                    }
                case "&":
                    i += 1
                    if i < scalars.count && scalars[i] == "&" { i += 1 }
                    tokens.append(.and)
                case "|":
                    i += 1
                    if i < scalars.count && scalars[i] == "|" { i += 1 }
                    tokens.append(.or)
                case "'":
                    i += 1
                    var value = ""
                    var terminated = false
                    while i < scalars.count {
                        if scalars[i] == "'" {
                            terminated = true
                            i += 1
                            break
                        }
                        value.unicodeScalars.append(scalars[i])
                        i += 1
                    }
                    tokens.append(terminated ? .string(value) : .invalid)
                case "/":
                    i += 1
                    var pattern = ""
                    var terminated = false
                    while i < scalars.count {
                        if scalars[i] == "\\" && i + 1 < scalars.count {
                            if scalars[i + 1] == "/" {
                                pattern.unicodeScalars.append("/")
                            } else {
                                pattern.unicodeScalars.append(scalars[i])
                                pattern.unicodeScalars.append(scalars[i + 1])
                            }
                            i += 2
                            continue
                        }
                        if scalars[i] == "/" {
                            terminated = true
                            i += 1
                            break
                        }
                        pattern.unicodeScalars.append(scalars[i])
                        i += 1
                    }
                    if terminated, let regex = ShortcutRegex(pattern: pattern) {
                        tokens.append(.regex(regex))
                    } else {
                        tokens.append(.invalid)
                    }
                default:
                    if isDigit(scalar) {
                        var text = ""
                        while i < scalars.count && isDigit(scalars[i]) {
                            text.unicodeScalars.append(scalars[i])
                            i += 1
                        }
                        if let value = Int(text) {
                            tokens.append(.number(value))
                        } else {
                            tokens.append(.invalid)
                        }
                    } else if isIdentifierScalar(scalar) {
                        var name = ""
                        while i < scalars.count && isIdentifierScalar(scalars[i]) {
                            name.unicodeScalars.append(scalars[i])
                            i += 1
                        }
                        tokens.append(.identifier(name))
                    } else {
                        tokens.append(.invalid)
                        i += 1
                    }
                }
            }
            return tokens
        }
    }
}
