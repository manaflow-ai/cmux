/// A binding's `when` clause compiled once per binding table: its tests of the
/// legacy context bits (`terminalFocused`, `!codeEditorFocused`, ...) become masks checked
/// against ``ActionContext`` in one AND each, so a key-down resolves without a dictionary lookup
/// per bit test. Tests the bits cannot answer (`==`, `!=`, `=~`, `in`, a key with no bit) stay
/// ``WhenClause`` leaves and are interpreted.
///
/// Chromium decides a command's state ahead of the key the same way: the enabled state is kept
/// per command and read in O(1) when an accelerator fires (chrome/browser/command_updater_impl.cc,
/// `IsCommandEnabled`), instead of being recomputed from the focus on every key.
///
/// Evaluation equals ``WhenClause/evaluate(_:)`` for every clause and context: `has(k)` holds
/// exactly when `k`'s bit is in ``KeyContext/bits`` (both read `isTruthy`), and the rewrites
/// (merged conjunctions, De Morgan on `!(a || b)`) are boolean identities.
public nonisolated struct CompiledWhen: Hashable, Sendable {
    /// What a compiled clause reads: a context and its bits, computed once per key-down.
    public nonisolated struct Input: Sendable {
        public let context: KeyContext
        public let bits: ActionContext

        public init(_ context: KeyContext) {
            self.context = context
            bits = context.bits
        }
    }

    nonisolated indirect enum Node: Hashable, Sendable {
        case constant(Bool)
        /// Every `required` bit is set and no `forbidden` bit is set.
        case masks(required: ActionContext, forbidden: ActionContext)
        /// At least one of the bits is set.
        case anyOf(ActionContext)
        case not(Node)
        case and([Node])
        case or([Node])
        /// A test the bits cannot answer, interpreted.
        case clause(WhenClause)
    }

    let root: Node

    /// A clause that always holds (an entry with no `when`).
    public static let always = CompiledWhen(root: .constant(true))

    public init(_ clause: WhenClause?) {
        root = clause.map(Self.compile) ?? .constant(true)
    }

    private init(root: Node) {
        self.root = root
    }

    public func evaluate(_ input: Input) -> Bool {
        root.evaluate(input)
    }

    /// No test of this clause reads the context's dictionary: the bits decide it.
    public var usesOnlyBits: Bool { root.usesOnlyBits }

    private static let bitByName: [String: ActionContext] = Dictionary(
        ActionContext.keyNames.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })

    private static func compile(_ clause: WhenClause) -> Node {
        switch clause {
        case .constant(let value):
            return .constant(value)
        case .has(let key):
            guard let bit = bitByName[key] else { return .clause(clause) }
            return .masks(required: bit, forbidden: [])
        case .not(let inner):
            return negate(compile(inner))
        case .and(let clauses):
            return conjunction(clauses.map(compile))
        case .or(let clauses):
            return disjunction(clauses.map(compile))
        case .equals, .notEquals, .matches, .isIn:
            return .clause(clause)
        }
    }

    private static func negate(_ node: Node) -> Node {
        switch node {
        case .constant(let value):
            return .constant(!value)
        case .masks(let required, let forbidden) where forbidden.isEmpty && required.rawValue.nonzeroBitCount == 1:
            return .masks(required: [], forbidden: required)
        case .masks(let required, let forbidden) where required.isEmpty && forbidden.rawValue.nonzeroBitCount == 1:
            return .masks(required: forbidden, forbidden: [])
        case .anyOf(let bits):
            // !(a || b) == !a && !b
            return .masks(required: [], forbidden: bits)
        case .not(let inner):
            return inner
        default:
            return .not(node)
        }
    }

    /// One mask node first (it fails fast with no lookup), then the other terms in order.
    private static func conjunction(_ nodes: [Node]) -> Node {
        var required: ActionContext = []
        var forbidden: ActionContext = []
        var rest: [Node] = []
        func add(_ node: Node) {
            switch node {
            case .constant(true): break
            case .masks(let r, let f):
                required.formUnion(r)
                forbidden.formUnion(f)
            case .and(let inner): for term in inner { add(term) }
            default: rest.append(node)
            }
        }
        for node in nodes { add(node) }
        if rest.contains(.constant(false)) || !required.isDisjoint(with: forbidden) { return .constant(false) }
        let masks: [Node] = required.isEmpty && forbidden.isEmpty ? [] : [.masks(required: required, forbidden: forbidden)]
        let terms = masks + rest
        switch terms.count {
        case 0: return .constant(true)
        case 1: return terms[0]
        default: return .and(terms)
        }
    }

    /// One `anyOf` node for the single-bit terms first, then the other terms in order.
    private static func disjunction(_ nodes: [Node]) -> Node {
        var anyBits: ActionContext = []
        var rest: [Node] = []
        func add(_ node: Node) {
            switch node {
            case .constant(false): break
            case .masks(let required, let forbidden) where forbidden.isEmpty && required.rawValue.nonzeroBitCount == 1:
                anyBits.formUnion(required)
            case .anyOf(let bits): anyBits.formUnion(bits)
            case .or(let inner): for term in inner { add(term) }
            default: rest.append(node)
            }
        }
        for node in nodes { add(node) }
        if rest.contains(.constant(true)) { return .constant(true) }
        let anyTerm: [Node] = switch anyBits.rawValue.nonzeroBitCount {
        case 0: []
        case 1: [.masks(required: anyBits, forbidden: [])]
        default: [.anyOf(anyBits)]
        }
        let terms = anyTerm + rest
        switch terms.count {
        case 0: return .constant(false)
        case 1: return terms[0]
        default: return .or(terms)
        }
    }
}

extension CompiledWhen.Node {
    nonisolated func evaluate(_ input: CompiledWhen.Input) -> Bool {
        switch self {
        case .constant(let value):
            return value
        case .masks(let required, let forbidden):
            return input.bits.isSuperset(of: required) && input.bits.isDisjoint(with: forbidden)
        case .anyOf(let bits):
            return !input.bits.isDisjoint(with: bits)
        case .not(let node):
            return !node.evaluate(input)
        case .and(let nodes):
            return nodes.allSatisfy { $0.evaluate(input) }
        case .or(let nodes):
            return nodes.contains { $0.evaluate(input) }
        case .clause(let clause):
            return clause.evaluate(input.context)
        }
    }

    nonisolated var usesOnlyBits: Bool {
        switch self {
        case .constant, .masks, .anyOf: true
        case .not(let node): node.usesOnlyBits
        case .and(let nodes), .or(let nodes): nodes.allSatisfy(\.usesOnlyBits)
        case .clause: false
        }
    }
}
