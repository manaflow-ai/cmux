/// A modifier named in a complex modification's `from.modifiers` or
/// `to.modifiers`.
enum KarabinerModifierRequirement: Sendable, Hashable {
    /// `control`, `shift`, `option`, `command`: either side.
    case either(KeyboardModifier)
    /// A side-specific modifier, `caps_lock`, or `fn`.
    case exact(PhysicalKey)
    /// `any`, in `optional` only: every other modifier may be held.
    case any

    init?(name: String) {
        switch name {
        case "control": self = .either(.control)
        case "shift": self = .either(.shift)
        case "option": self = .either(.option)
        case "command": self = .either(.command)
        case "any": self = .any
        default:
            guard let key = PhysicalKey(karabinerKeyCode: name), key.isHoldable else { return nil }
            self = .exact(key)
        }
    }

    /// Whether a held key satisfies this requirement.
    func isSatisfied(by key: PhysicalKey) -> Bool {
        switch self {
        case let .either(modifier): key.modifier == modifier
        case let .exact(exact): key == exact
        case .any: true
        }
    }

    /// The key Karabiner sends for this modifier in `to.modifiers`: the
    /// left side for a two-sided name.
    var sentKey: PhysicalKey? {
        switch self {
        case let .either(modifier): modifier.leftKey
        case let .exact(key): key
        case .any: nil
        }
    }

    /// Keys that satisfy the requirement, left side first.
    var satisfyingKeys: [PhysicalKey] {
        switch self {
        case let .either(modifier): [modifier.leftKey, modifier.rightKey]
        case let .exact(key): [key]
        case .any: []
        }
    }

    /// Parses a `modifiers` value: an array of names or a single name.
    /// Returns `nil` when a name is unknown.
    static func list(_ value: Any?) -> [KarabinerModifierRequirement]? {
        guard let value else { return [] }
        let names: [String]
        if let single = value as? String {
            names = [single]
        } else if let many = value as? [String] {
            names = many
        } else {
            return nil
        }
        var requirements: [KarabinerModifierRequirement] = []
        for name in names {
            guard let requirement = KarabinerModifierRequirement(name: name) else { return nil }
            requirements.append(requirement)
        }
        return requirements
    }
}
