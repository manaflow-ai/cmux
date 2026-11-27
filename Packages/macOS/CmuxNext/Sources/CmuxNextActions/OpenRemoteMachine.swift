/// A machine `cmux open-remote <host>` can name, reduced to what matching needs.
public nonisolated struct OpenRemoteMachine: Sendable, Hashable {
    public let id: String
    public let name: String
    /// The ssh destination (`user@host` or a host).
    public let destination: String

    public init(id: String, name: String, destination: String) {
        self.id = id
        self.name = name
        self.destination = destination
    }

    /// The machine `text` names: its id, then its name, then its destination, then the
    /// destination's host part (without `user@`); case-insensitive, first match wins.
    public static func match(_ text: String, in machines: [OpenRemoteMachine]) -> OpenRemoteMachine? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        let lookups: [(OpenRemoteMachine) -> String] = [
            { $0.id }, { $0.name }, { $0.destination },
            { $0.destination.split(separator: "@").last.map(String.init) ?? $0.destination },
        ]
        for lookup in lookups {
            if let found = machines.first(where: { lookup($0).lowercased() == wanted }) { return found }
        }
        return nil
    }
}
