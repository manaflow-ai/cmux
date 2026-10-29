/// What a touch or a finding is about (plans/cmux-next/invariants-DESIGN.md section 2.2). A violation's signature
/// is its rule id, its host and its subject: one signature is reported once until a later check finds it clear.
/// It compiles in every build, because a Release probe call names it (and does nothing with it).
///
/// In JSON a subject is an object with one member: `{"window": "w2"}`, `{"surface": 7}`, `{"app": true}`.
public enum InvariantSubject: Hashable, Sendable, CustomStringConvertible {
    case app
    case window(String)
    case pane(String)
    case surface(UInt64)
    case page(String)
    case node(UInt64)
    /// A machine's daemon (its mirror, M1).
    case machine(String)

    public var description: String {
        switch self {
        case .app: "app"
        case .window(let id): "window:\(id)"
        case .pane(let id): "pane:\(id)"
        case .surface(let id): "surface:\(id)"
        case .page(let id): "page:\(id)"
        case .node(let id): "node:\(id)"
        case .machine(let id): "machine:\(id)"
        }
    }

    /// The window id of a `.window` subject.
    public var windowID: String? {
        if case .window(let id) = self { return id }
        return nil
    }
}

extension InvariantSubject: Codable {
    private enum Member: String, CodingKey {
        case app, window, pane, surface, page, node, machine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Member.self)
        guard let member = container.allKeys.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "an invariant subject has one member"))
        }
        switch member {
        case .app: self = .app
        case .window: self = .window(try container.decode(String.self, forKey: member))
        case .pane: self = .pane(try container.decode(String.self, forKey: member))
        case .surface: self = .surface(try container.decode(UInt64.self, forKey: member))
        case .page: self = .page(try container.decode(String.self, forKey: member))
        case .node: self = .node(try container.decode(UInt64.self, forKey: member))
        case .machine: self = .machine(try container.decode(String.self, forKey: member))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Member.self)
        switch self {
        case .app: try container.encode(true, forKey: .app)
        case .window(let id): try container.encode(id, forKey: .window)
        case .pane(let id): try container.encode(id, forKey: .pane)
        case .surface(let id): try container.encode(id, forKey: .surface)
        case .page(let id): try container.encode(id, forKey: .page)
        case .node(let id): try container.encode(id, forKey: .node)
        case .machine(let id): try container.encode(id, forKey: .machine)
        }
    }
}
