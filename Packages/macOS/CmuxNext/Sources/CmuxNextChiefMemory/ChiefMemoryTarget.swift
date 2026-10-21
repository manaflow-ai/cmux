/// One thing in a Chief's memory that a person can edit or delete.
public enum ChiefMemoryTarget: Sendable, Hashable {
    /// A message or note of the log, by its id.
    case message(UInt64)
    /// A summary line of the tree, by its node name (`id+n`).
    case line(String)

    /// The `target` query value of the change paths: `message:<id>` or `node:<id+n>`.
    public var queryValue: String {
        switch self {
        case .message(let id): "message:\(id)"
        case .line(let name): "node:\(name)"
        }
    }

    /// How the change list names it.
    public var label: String {
        switch self {
        case .message(let id): String(format: ChiefMemoryStrings.messageLabel, Int(id))
        case .line(let name): String(format: ChiefMemoryStrings.lineLabel, name)
        }
    }
}
