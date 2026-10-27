package import CmuxNextActions

/// Seeded clauses and contexts over the legacy bit keys and the string keys `when` clauses read
/// (CompiledWhenTests in CmuxNextActionsTests, KeyBindingTableTests in CmuxNextActionsAppKitTests).
package nonisolated struct WhenFuzz {
    private nonisolated struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var rng: SplitMix64
    private let bitNames = ActionContext.keyNames.map(\.1)
    private var textKeys = [KeyContext.surfaceKind, KeyContext.focus, KeyContext.pageID, KeyContext.topPage,
                            KeyContext.textInputFocus, KeyContext.listFocus, KeyContext.terminalCopyMode, "custom.count"]
    private var texts: [KeyContextValue] = [.string("terminal"), .string("page"), .string("home"), .string("agent"),
                                            .string("content"), .string("omnibar"), .string(""), .number(0), .number(1),
                                            .number(2.5), .bool(true), .bool(false)]
    /// Key and value pairs the clauses compare, so a context often makes `==` hold.
    private var pairs: [(String, KeyContextValue)] = []
    private let patterns = ["^term", "home|page", "a.*", "(", ""]
    private let listKey = "custom.list"

    package init(seed: UInt64, clauses: [WhenClause] = []) {
        rng = SplitMix64(state: seed)
        for clause in clauses { collect(clause) }
    }

    private mutating func collect(_ clause: WhenClause) {
        switch clause {
        case .constant: break
        case .has(let key): if !bitNames.contains(key), !textKeys.contains(key) { textKeys.append(key) }
        case .not(let inner): collect(inner)
        case .and(let inner), .or(let inner): for term in inner { collect(term) }
        case .equals(let key, let value), .notEquals(let key, let value):
            pairs.append((key, value))
            if !textKeys.contains(key) { textKeys.append(key) }
        case .matches(let key, _), .isIn(let key, _): if !textKeys.contains(key) { textKeys.append(key) }
        }
    }

    private mutating func chance(_ percent: UInt64) -> Bool { rng.next() % 100 < percent }

    private mutating func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }

    package mutating func clause(depth: Int) -> WhenClause {
        if depth == 0 || chance(30) { return leaf() }
        let roll = rng.next() % 100
        if roll < 20 { return .not(clause(depth: depth - 1)) }
        let terms = (0..<Int(rng.next() % 5)).map { _ in clause(depth: depth - 1) }
        return roll < 60 ? .and(terms) : .or(terms)
    }

    private mutating func leaf() -> WhenClause {
        let roll = rng.next() % 100
        switch roll {
        case ..<5: return .constant(chance(50))
        case ..<55: return .has(pick(bitNames))
        case ..<62: return .has(pick(textKeys))
        case ..<74: return .equals(pick(textKeys + bitNames), pick(texts))
        case ..<86: return .notEquals(pick(textKeys + bitNames), pick(texts))
        case ..<93: return .matches(pick(textKeys), pattern: pick(patterns))
        default: return .isIn(pick(textKeys), listKey: listKey)
        }
    }

    package mutating func context() -> KeyContext {
        var context = KeyContext()
        let truthy: [KeyContextValue] = [.bool(true), .bool(true), .bool(true), .bool(false), .string(""), .string("x"),
                                         .number(0), .number(1), .strings([]), .strings(["a"])]
        for name in bitNames where chance(35) { context[name] = pick(truthy) }
        for key in textKeys where chance(40) { context[key] = pick(texts) }
        if !pairs.isEmpty {
            for _ in 0..<Int(rng.next() % 4) {
                let (key, value) = pick(pairs)
                context[key] = value
            }
        }
        if chance(60) { context[listKey] = chance(80) ? .strings(["terminal", "home", "1"]) : .string("terminal") }
        return context
    }

    /// Contexts the key router builds for common focus.
    package static let namedContexts: [KeyContext] = [
        KeyContext(),
        KeyContext(["terminalFocused": .bool(true), KeyContext.surfaceKind: .string("terminal"), KeyContext.focus: .string("content")]),
        KeyContext(["browserFocused": .bool(true), "webViewFocused": .bool(true), KeyContext.surfaceKind: .string("page")]),
        KeyContext(["browserFocused": .bool(true), "omnibarFocused": .bool(true), KeyContext.textInputFocus: .bool(true),
                    KeyContext.focus: .string("omnibar")]),
        KeyContext(["codeEditorFocused": .bool(true), KeyContext.surfaceKind: .string("cmux.codeEditor")]),
        KeyContext([KeyContext.topPage: .string("home"), KeyContext.surfaceKind: .string("home")]),
        KeyContext(["paletteOpen": .bool(true), KeyContext.listFocus: .bool(true), KeyContext.paletteQueryEmpty: .bool(true)]),
        KeyContext(["agentPaneFocused": .bool(true), KeyContext.surfaceKind: .string("agent"), KeyContext.textInputFocus: .bool(true)]),
    ]
}
