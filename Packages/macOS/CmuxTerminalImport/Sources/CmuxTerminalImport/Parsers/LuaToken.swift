/// One token of a WezTerm Lua config.
struct LuaToken: Equatable {
    enum Kind: Equatable {
        case name
        case string
        case number
        case symbol
    }

    var kind: Kind
    var text: String
    var line: Int
}
