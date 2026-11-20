/// One edit of a place's widget layout (`apps.widgets.layout.edit {place, edit, idempotency_key}`).
/// The daemon takes it only from a person's gesture (origin `user` on the verified app connection),
/// checks it against the widget's spec, saves it and tells every client (`apps-widgets-changed`).
public nonisolated enum AppWidgetEdit: Sendable, Hashable {
    /// Places `app`'s widget at `size` (its default for the place when nil), before the tile
    /// `before` (at the end when nil).
    case add(app: String, size: AppWidgetSize?, before: String?)
    case remove(instance: String)
    case resize(instance: String, size: AppWidgetSize)
    /// Moves a tile before `before`, or to the end.
    case move(instance: String, before: String?)

    /// The edit as the wire's `edit` object.
    public var json: AppJSON {
        var object: [String: AppJSON]
        switch self {
        case let .add(app, size, before):
            object = ["op": "add", "app": .string(app)]
            if let size { object["size"] = .string(size.rawValue) }
            if let before { object["before"] = .string(before) }
        case let .remove(instance):
            object = ["op": "remove", "instance": .string(instance)]
        case let .resize(instance, size):
            object = ["op": "resize", "instance": .string(instance), "size": .string(size.rawValue)]
        case let .move(instance, before):
            object = ["op": "move", "instance": .string(instance)]
            if let before { object["before"] = .string(before) }
        }
        return .object(object)
    }

    /// The tiles as they are after this edit (what the area draws while the daemon commits it).
    /// An add has no instance yet, so it changes nothing here.
    public func applied(to tiles: [AppWidgetTile]) -> [AppWidgetTile] {
        var tiles = tiles
        switch self {
        case .add:
            break
        case let .remove(instance):
            tiles.removeAll { $0.instance == instance }
        case let .resize(instance, size):
            if let index = tiles.firstIndex(where: { $0.instance == instance }) { tiles[index].size = size }
        case let .move(instance, before):
            guard let from = tiles.firstIndex(where: { $0.instance == instance }) else { break }
            let tile = tiles.remove(at: from)
            let to = before.flatMap { target in tiles.firstIndex { $0.instance == target } } ?? tiles.count
            tiles.insert(tile, at: to)
        }
        return tiles
    }
}
