/// A literal value read from a WezTerm config: the only kind of Lua the importer evaluates.
indirect enum LuaValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    /// A table constructor; positional entries have a `nil` key.
    case table([Entry])
    /// `wezterm.font(...)` or `wezterm.font_with_fallback(...)`, reduced to the primary family.
    case font(String)

    struct Entry: Equatable {
        var key: String?
        var value: LuaValue
    }

    subscript(key: String) -> LuaValue? {
        guard case .table(let entries) = self else { return nil }
        return entries.last { $0.key == key }?.value
    }

    var positional: [LuaValue] {
        guard case .table(let entries) = self else { return [] }
        return entries.filter { $0.key == nil }.map(\.value)
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
