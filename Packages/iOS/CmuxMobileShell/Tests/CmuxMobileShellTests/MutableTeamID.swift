/// Mutable team holder so tests can simulate a Stack team switch mid-session.
actor MutableTeamID {
    var value: String?

    init(_ value: String?) {
        self.value = value
    }

    func set(_ value: String?) {
        self.value = value
    }
}
