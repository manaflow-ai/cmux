/// The user's palette ranking settings (cmux.json `palette.aliases` and `palette.pins`, cx-9ce.43):
/// an alias names a command, and pinned commands lead the empty palette.
public nonisolated struct PaletteRankSettings: Sendable, Equatable {
    /// Words by action id: a query that is one of an action's words puts its row first.
    public var aliases: [String: [String]]
    /// Action ids shown first on the empty query, in this order.
    public var pins: [String]

    public init(aliases: [String: [String]] = [:], pins: [String] = []) {
        self.aliases = aliases
        self.pins = pins
    }
}
