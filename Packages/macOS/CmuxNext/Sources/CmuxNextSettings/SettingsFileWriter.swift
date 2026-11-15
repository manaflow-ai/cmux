public import Foundation

/// One edit of `cmux-next.json`, as the daemon's `settings.edit` takes it (cmux-config `EditKind`).
public nonisolated enum SettingsFileEdit: Sendable, Equatable {
    /// Sets the value at the path (`settings.set`); a schema row set to its default loses its key.
    case set([String], JSONValue)
    /// Sets the value only while the file has none at the path (JSON null is a value).
    case setUnset([String], JSONValue)
    /// Removes the key (`settings.reset`).
    case reset([String])
    /// Removes the key only while the file still holds this value there.
    case resetUnchanged([String], JSONValue)

    public var path: [String] {
        switch self {
        case .set(let path, _), .setUnset(let path, _), .reset(let path), .resetUnchanged(let path, _): path
        }
    }

    /// The edit as `settings.edit` takes it: `{op, path, value?}`.
    public var wire: JSONValue {
        let path = JSONValue.array(path.map(JSONValue.string))
        return switch self {
        case .set(_, let value): ["op": "set", "path": path, "value": value]
        case .setUnset(_, let value): ["op": "set_unset", "path": path, "value": value]
        case .reset: ["op": "reset", "path": path]
        case .resetUnchanged(_, let value): ["op": "reset_unchanged", "path": path, "value": value]
        }
    }
}

/// The one writer of `cmux-next.json`: in the app, the home daemon's settings owner (cmux-tui
/// `cmux-config`, `settings.edit`), which edits the JSONC text in place (comments and unknown keys
/// stay), publishes it atomically and bumps the settings revision (plans/cmux-next/settings-react.md
/// section 1). The app never writes the file itself.
public protocol SettingsFileWriter: Sendable {
    /// Applies `edits` in order to the settings file at `file` in one publish. Returns the indexes of
    /// the edits that applied (a conditional edit whose condition did not hold is left out). A
    /// refused edit refuses them all and writes nothing.
    func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int]
}

/// No daemon serves the settings file now (not connected, or it serves another file), so the write
/// was refused and wrote nothing. Nothing queues: the same write sent once it reconnects completes.
public nonisolated struct SettingsWriterDisconnected: Error, Sendable, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
        "settings cannot change while cmux is not connected to its daemon; nothing was written"
    }
}
