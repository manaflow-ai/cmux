actor CredentialPersistenceRecorder {
    private var events: [String] = []

    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}
