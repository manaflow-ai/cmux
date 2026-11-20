public import Foundation

/// One edit of `cmux-next.json`, as the daemon's `settings.edit` takes it (cmux-config `EditKind`).
public nonisolated enum SettingsFileEdit: Sendable, Equatable {
    /// Sets the value at the path as given (`set_exact`): a schema row set to its default keeps its
    /// key. The caller already decided keep or remove (`isUnsetValue`, the layers below the file,
    /// `SettingsSchema.unsetIsNotDefaultKeys`, build defaults), as when the app wrote the file itself.
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
        case .set(_, let value): ["op": "set_exact", "path": path, "value": value]
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

/// A writer that hands the edits on as `settings.edit` JSON (`[{op, path, value?}]`): the seam the
/// app fills with the home daemon's `edit(json:file:)`. `send` answers the indexes of the edits that
/// applied, or nil when no daemon can take the write (``SettingsWriterDisconnected``).
public nonisolated struct SettingsEditSender: SettingsFileWriter {
    let send: @Sendable (_ json: String, _ file: URL) async throws -> [Int]?

    public init(_ send: @escaping @Sendable (_ json: String, _ file: URL) async throws -> [Int]?) {
        self.send = send
    }

    /// An empty batch (a write that changes nothing) applies nothing and sends nothing:
    /// `settings.edit` takes 1 to 1000 edits.
    public func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int] {
        if edits.isEmpty { return [] }
        guard let applied = try await send(JSONValue.array(edits.map(\.wire)).compactText, file) else {
            throw SettingsWriterDisconnected()
        }
        return applied
    }
}
