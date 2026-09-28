/// One `basic` manipulator from a complex modification rule.
///
/// cmux inverts only the plain shape: `from` one `key_code` with
/// `modifiers.mandatory` and `modifiers.optional`, `to` exactly one
/// `key_code` with `modifiers`. Anything else (`to_if_alone`,
/// `to_after_key_up`, several outputs, `set_variable`, `simultaneous`) keeps
/// the key it applies to but is marked unsupported, so a chord that reaches
/// it resolves to "unknown" rather than a guess.
struct KarabinerManipulator: Sendable, Equatable {
    /// What the manipulator listens for.
    enum From: Sendable, Equatable {
        /// A single key with modifier requirements.
        case key(PhysicalKey, mandatory: [KarabinerModifierRequirement], optional: [KarabinerModifierRequirement])
        /// Some shape cmux doesn't read that involves these keys.
        case keys(Set<PhysicalKey>)
        /// A shape that could involve any key (`any`, unknown key names).
        case anyKey
        /// Not a keyboard key (`consumer_key_code`, `pointing_button`).
        case noKeyboardKey
    }

    /// What the manipulator sends.
    enum Output: Sendable, Equatable {
        /// One key with modifiers held.
        case key(PhysicalKey, modifiers: [PhysicalKey])
        /// Anything else.
        case unsupported
    }

    /// The result of pressing a key with some keys held.
    enum Match: Equatable {
        /// The manipulator doesn't take the key.
        case unmatched
        /// It takes the key and sends `key` with `held` still held.
        case sends(key: PhysicalKey, held: [PhysicalKey])
        /// It may take the key and cmux can't tell what it sends.
        case unknown
    }

    var from: From
    var output: Output
    var conditions: [KarabinerCondition]

    private static let plainKeys: Set<String> = ["type", "from", "to", "conditions", "description", "parameters"]

    init(from: From, output: Output, conditions: [KarabinerCondition] = []) {
        self.from = from
        self.output = output
        self.conditions = conditions
    }

    init?(json: [String: Any]) {
        guard (json["type"] as? String ?? "basic") == "basic" else { return nil }
        conditions = (json["conditions"] as? [[String: Any]] ?? []).map(KarabinerCondition.init(json:))
        from = Self.from(json["from"] as? [String: Any] ?? [:])
        let isPlain = Set(json.keys).isSubset(of: Self.plainKeys)
        output = isPlain ? Self.output(json["to"]) : .unsupported
    }

    /// What pressing `key` with `held` down does, once conditions hold.
    func match(key: PhysicalKey, held: [PhysicalKey]) -> Match {
        switch from {
        case .noKeyboardKey:
            return .unmatched
        case .anyKey:
            return .unknown
        case let .keys(keys):
            return keys.contains(key) ? .unknown : .unmatched
        case let .key(fromKey, mandatory, optional):
            guard fromKey == key, let rest = Self.remaining(held, mandatory: mandatory, optional: optional) else {
                return .unmatched
            }
            guard case let .key(sent, modifiers) = output else { return .unknown }
            return .sends(key: sent, held: rest + modifiers)
        }
    }

    /// Held keys left once `mandatory` takes its keys, or `nil` when a
    /// mandatory modifier is missing or an extra one isn't optional.
    static func remaining(
        _ held: [PhysicalKey],
        mandatory: [KarabinerModifierRequirement],
        optional: [KarabinerModifierRequirement]
    ) -> [PhysicalKey]? {
        var rest = held
        for requirement in mandatory {
            guard let index = rest.firstIndex(where: requirement.isSatisfied(by:)) else { return nil }
            rest.remove(at: index)
        }
        if !optional.contains(.any) {
            guard rest.allSatisfy({ key in optional.contains { $0.isSatisfied(by: key) } }) else { return nil }
        }
        return rest
    }

    private static func from(_ json: [String: Any]) -> From {
        if let name = json["key_code"] as? String {
            guard let key = PhysicalKey(karabinerKeyCode: name) else { return .anyKey }
            let modifiers = json["modifiers"] as? [String: Any] ?? [:]
            let knownFields: Set<String> = ["key_code", "modifiers"]
            guard Set(json.keys).isSubset(of: knownFields),
                  Set(modifiers.keys).isSubset(of: ["mandatory", "optional"]),
                  let mandatory = KarabinerModifierRequirement.list(modifiers["mandatory"]),
                  !mandatory.contains(.any),
                  let optional = KarabinerModifierRequirement.list(modifiers["optional"]) else {
                return .keys([key])
            }
            return .key(key, mandatory: mandatory, optional: optional)
        }
        if let simultaneous = json["simultaneous"] as? [[String: Any]] {
            var keys = Set<PhysicalKey>()
            for entry in simultaneous {
                guard let name = entry["key_code"] as? String else { continue }
                guard let key = PhysicalKey(karabinerKeyCode: name) else { return .anyKey }
                keys.insert(key)
            }
            return .keys(keys)
        }
        if json["any"] != nil { return .anyKey }
        if json["consumer_key_code"] != nil || json["pointing_button"] != nil || json["apple_vendor_top_case_key_code"] != nil {
            return .noKeyboardKey
        }
        return .anyKey
    }

    private static func output(_ value: Any?) -> Output {
        let entries: [Any]
        if let array = value as? [Any] {
            entries = array
        } else if let single = value as? [String: Any] {
            entries = [single]
        } else {
            return .unsupported
        }
        guard entries.count == 1, let entry = entries.first as? [String: Any],
              Set(entry.keys).isSubset(of: ["key_code", "modifiers", "lazy", "repeat", "halt", "description"]),
              let name = entry["key_code"] as? String, let key = PhysicalKey(karabinerKeyCode: name),
              let modifiers = KarabinerModifierRequirement.list(entry["modifiers"]) else {
            return .unsupported
        }
        var keys: [PhysicalKey] = []
        for modifier in modifiers {
            guard let sent = modifier.sentKey else { return .unsupported }
            keys.append(sent)
        }
        return .key(key, modifiers: keys)
    }
}
