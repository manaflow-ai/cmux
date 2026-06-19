public import Foundation

/// The dispatch backend that executes a card's task.
///
/// `cmux` runs the task as a native agent session in-process (the default);
/// `cnvs` proxies to a running CNVS "Forge" via its CLI/MCP; `hermes` posts to
/// a Hermes agent gateway over loopback HTTP. Decoding is tolerant: an unknown
/// raw value falls back to ``cmux``.
public enum KanbanBackendKind: String, CaseIterable, Codable, Sendable {
    case cmux
    case cnvs
    case hermes

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KanbanBackendKind(rawValue: raw) ?? .cmux
    }
}
