import Foundation

/// The user's keybindings.json as the daemon owns it (`keybindings-v1`,
/// K-T6, cx-9ce.17): beside the settings file, edited in place (comments
/// stay) and published atomically. The app loads the entries into its
/// binding table and validates them against the catalog; the daemon checks
/// only the key syntax.
public struct KeybindingsFileClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// One entry of the file, in its order. A removal (`"-command"`) has no
    /// keys when it removes every key of the command.
    public struct Entry: Decodable, Sendable, Hashable {
        public var index: Int
        /// Normalized strokes: `["ctrl+k", "s"]`.
        public var keys: [String]
        public var command: String
        public var when: String?
        public var args: [String: JSONValue]?
        public var removal: Bool
    }

    /// Why an entry (or, with no index, the whole file) did not load.
    public struct Diagnostic: Decodable, Sendable, Hashable {
        public var index: Int?
        public var problem: String
        public var message: String
    }

    public struct Snapshot: Decodable, Sendable {
        public var path: String
        /// Decimal string.
        public var revision: String
        public var entries: [Entry]
        public var diagnostics: [Diagnostic]
    }

    /// One binding an edit names: keys in keybindings.json syntax and the
    /// `when` text as `get` returned it.
    public struct Binding: Sendable, Hashable {
        public var command: String
        public var key: String
        public var when: String?

        public init(command: String, key: String, when: String?) {
            self.command = command
            self.key = key
            self.when = when
        }

        var params: [String: JSONValue] {
            var params: [String: JSONValue] = ["command": .string(command), "key": .string(key)]
            if let when { params["when"] = .string(when) }
            return params
        }
    }

    public func get() async throws -> Snapshot {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "keybindings.get", params: [:], idempotencyKey: nil)
        }, as: Snapshot.self)
    }

    /// Binds `binding` with `args`; with `replaces`, that binding goes (a
    /// default is written as a removal).
    public func set(_ binding: Binding, args: [String: JSONValue], replaces: Binding?, idempotencyKey: String) async throws {
        var params = binding.params
        params["origin"] = .string("app")
        if !args.isEmpty { params["args"] = .object(args) }
        if let replaces { params["replaces"] = .object(replaces.params) }
        try await mutation("keybindings.set", params, idempotencyKey)
    }

    /// Unbinds one binding of a command (a default is written as a removal).
    public func remove(_ binding: Binding, idempotencyKey: String) async throws {
        var params = binding.params
        params["origin"] = .string("app")
        try await mutation("keybindings.remove", params, idempotencyKey)
    }

    /// Drops every entry and removal of `command`: its defaults return.
    public func reset(command: String, idempotencyKey: String) async throws {
        try await mutation("keybindings.reset", ["command": .string(command), "origin": .string("app")], idempotencyKey)
    }

    private func mutation(_ operation: String, _ params: [String: JSONValue], _ idempotencyKey: String) async throws {
        _ = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
    }
}
