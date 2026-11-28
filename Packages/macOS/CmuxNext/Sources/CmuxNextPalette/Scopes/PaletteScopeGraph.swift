public import Foundation

/// Every palette scope and how scopes enter each other: which prefix or
/// keyword enters which child from a given parent. Pure and immutable; the
/// reducer reads it as its environment.
nonisolated public struct PaletteScopeGraph: Sendable {
    /// Why a descriptor was left out of the graph.
    public enum Problem: Hashable, Sendable {
        /// The root id is reserved for the full palette.
        case reservedID(PaletteScopeID)
        case duplicateID(PaletteScopeID)
        /// A prefix must be one punctuation or symbol character.
        case invalidPrefix(PaletteScopeID, String)
        /// Two scopes enterable from the same parent share a prefix; the
        /// later one loses its prefix.
        case prefixCollision(PaletteScopeID, with: PaletteScopeID, prefix: String)
        /// Two scopes enterable from the same parent share a keyword; the
        /// later one loses that keyword.
        case keywordCollision(PaletteScopeID, with: PaletteScopeID, keyword: String)
    }

    public let root: PaletteScopeDescriptor
    public private(set) var scopes: [PaletteScopeID: PaletteScopeDescriptor] = [:]
    /// Scopes in registration order (the scope list, `palette.scopes`).
    public private(set) var order: [PaletteScopeID] = []
    public private(set) var problems: [Problem] = []

    /// Registers `descriptors` in order. A later descriptor that collides
    /// with an earlier one keeps its id but loses the colliding prefix or
    /// keyword (user assignments are registered first, so they win).
    public init(root: PaletteScopeDescriptor, scopes descriptors: [PaletteScopeDescriptor]) {
        // The root has no prefix, keyword or parent: it is only ever level 0.
        self.root = PaletteScopeDescriptor(
            id: .root, title: root.title, symbol: root.symbol, placeholder: root.placeholder,
            parents: .only([]), emptyQuerySelection: root.emptyQuerySelection, openAction: root.openAction, owner: root.owner
        )
        for descriptor in descriptors { register(descriptor) }
    }

    private mutating func register(_ input: PaletteScopeDescriptor) {
        var descriptor = input
        if descriptor.id == .root {
            problems.append(.reservedID(descriptor.id))
            return
        }
        if scopes[descriptor.id] != nil {
            problems.append(.duplicateID(descriptor.id))
            return
        }
        let registered = order.compactMap { scopes[$0] }
        if let prefix = descriptor.prefix {
            if !Self.isValidPrefix(prefix) {
                problems.append(.invalidPrefix(descriptor.id, prefix))
                descriptor.prefix = nil
            } else if let other = registered.first(where: {
                $0.prefix == prefix && Self.parentsOverlap($0.parents, descriptor.parents)
            }) {
                problems.append(.prefixCollision(descriptor.id, with: other.id, prefix: prefix))
                descriptor.prefix = nil
            }
        }
        var keywords: [String] = []
        for keyword in descriptor.keywords where !keyword.isEmpty && !keywords.contains(keyword) {
            if let other = registered.first(where: {
                $0.keywords.contains(keyword) && Self.parentsOverlap($0.parents, descriptor.parents)
            }) {
                problems.append(.keywordCollision(descriptor.id, with: other.id, keyword: keyword))
            } else {
                keywords.append(keyword)
            }
        }
        descriptor.keywords = keywords
        scopes[descriptor.id] = descriptor
        order.append(descriptor.id)
    }

    /// One grapheme that is punctuation or a symbol.
    public static func isValidPrefix(_ prefix: String) -> Bool {
        guard prefix.count == 1, let scalar = prefix.unicodeScalars.first, prefix.unicodeScalars.count == 1 else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }

    /// Whether some parent allows both rule sets (conservative for
    /// `anywhere`).
    static func parentsOverlap(_ a: PaletteScopeDescriptor.Parents, _ b: PaletteScopeDescriptor.Parents) -> Bool {
        switch (a, b) {
        case (.anywhere, _), (_, .anywhere): true
        case (.root, .root): true
        case (.root, .only(let set)), (.only(let set), .root): set.contains(.root)
        case (.only(let x), .only(let y)): !x.isDisjoint(with: y)
        }
    }

    public func descriptor(_ id: PaletteScopeID) -> PaletteScopeDescriptor? {
        id == .root ? root : scopes[id]
    }

    public func contains(_ id: PaletteScopeID) -> Bool { id == .root || scopes[id] != nil }

    /// The scope that `prefix` enters from `parent`.
    public func child(of parent: PaletteScopeID, prefix: Character) -> PaletteScopeDescriptor? {
        let text = String(prefix)
        return order.lazy.compactMap { self.scopes[$0] }.first { $0.prefix == text && $0.parents.allows(parent) }
    }

    /// The scope whose keyword equals `text` (trimmed, case-insensitive)
    /// from `parent`.
    public func child(of parent: PaletteScopeID, keyword text: String) -> PaletteScopeDescriptor? {
        let keyword = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return nil }
        return order.lazy.compactMap { self.scopes[$0] }.first { $0.keywords.contains(keyword) && $0.parents.allows(parent) }
    }

    /// Whether `child` may be entered from `parent` by prefix, keyword or
    /// scope row.
    public func canEnter(_ child: PaletteScopeID, from parent: PaletteScopeID) -> Bool {
        scopes[child]?.parents.allows(parent) ?? false
    }

    /// Scopes enterable from `parent`, in registration order.
    public func children(of parent: PaletteScopeID) -> [PaletteScopeDescriptor] {
        order.compactMap { scopes[$0] }.filter { $0.parents.allows(parent) }
    }
}
