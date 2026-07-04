struct AgentStateColorRow: Identifiable {
    let rawValue: String
    let title: String
    let defaultHex: String?

    var id: String { rawValue }
}
