import Foundation

/// Decoding of owner lines shared by every source.
nonisolated enum TasksWire {
    private struct EventLine: Decodable {
        var seq: UInt64
        var tx: String
        var kind: String
        var change: ChangeLine
    }

    private struct ChangeLine: Decodable {
        var type: String
        var entity: String?
        var id: String?
        var value: EntityLine?
    }

    private struct EntityLine: Decodable {
        var change: TasksChange

        enum Key: String, CodingKey { case entity }

        init(from decoder: any Decoder) throws {
            let entity = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .entity)
            switch entity {
            case "task": change = .task(try TaskItem(from: decoder))
            case "status": change = .status(try TaskStatusItem(from: decoder))
            case "label": change = .label(try TaskLabelItem(from: decoder))
            case "project": change = .project(try TaskProjectItem(from: decoder))
            case "session": change = .session(try TaskSessionItem(from: decoder))
            case "settings": change = .settings(try TasksSettings(from: decoder))
            default: change = .other
            }
        }
    }

    private struct ReplyLine: Decodable {
        struct ErrorBody: Decodable { var message: String }
        var id: UInt64?
        var ok: AnyDecodable?
        var err: ErrorBody?
        var snapshot: TasksSnapshot?
        var event: EventLine?
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    enum Line {
        case snapshot(TasksSnapshot)
        case event(TasksEvent)
        case reply(id: UInt64, reject: String?)
        case ignored
    }

    static func decode(_ data: Data) -> Line {
        guard let line = try? JSONDecoder().decode(ReplyLine.self, from: data) else { return .ignored }
        if let snapshot = line.snapshot { return .snapshot(snapshot) }
        if let event = line.event {
            let change: TasksChange
            if event.change.type == "remove", let entity = event.change.entity, let id = event.change.id {
                change = .remove(entity: entity, id: id)
            } else {
                change = event.change.value?.change ?? .other
            }
            return .event(TasksEvent(seq: event.seq, tx: event.tx, kind: event.kind, change: change))
        }
        if let id = line.id, line.ok != nil || line.err != nil { return .reply(id: id, reject: line.err?.message) }
        return .ignored
    }
}
