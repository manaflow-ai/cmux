/// Mutable team holder so a test can simulate a team switch mid-session.
actor MutableTeam {
    var value: String
    init(_ value: String) { self.value = value }
    func set(_ value: String) { self.value = value }
}
