import Foundation

/// What the config scripts define (`script-config-v1`,
/// plans/cmux-next/scripting-runtime.md section 10.3): the daemon runs
/// `scripts/*.js` beside the settings file in one session and reports the
/// user actions, key bindings, key modes and default-binding removals they
/// made. The app registers the actions (`user.<name>`) and loads the
/// bindings as the table's app layer.
public struct ScriptConfigReport: Decodable, Sendable, Equatable {
    public struct Action: Decodable, Sendable, Equatable {
        /// `user.<name>`.
        public var id: String
        public var name: String
        public var title: String
        public var description: String?
        /// False for a function bound to a key (`user.key.<n>`).
        public var palette: Bool
    }

    public struct Key: Decodable, Sendable, Equatable {
        /// keybindings.json syntax: strokes separated by spaces (`cmd+k s`).
        public var key: String
        public var command: String
        public var args: [String: JSONValue]?
        public var when: String?
        /// The key mode the binding works in, nil for every mode.
        public var mode: String?
    }

    public struct Mode: Decodable, Sendable, Equatable {
        public var name: String
        public var title: String
        /// An exclusive mode swallows the keys it does not bind.
        public var exclusive: Bool
    }

    public struct Removal: Decodable, Sendable, Equatable {
        public var command: String
        /// Nil removes every key of `command`.
        public var key: String?
    }

    public struct Diagnostic: Decodable, Sendable, Equatable {
        public var file: String?
        public var line: Int?
        public var column: Int?
        public var code: String?
        public var message: String
    }

    /// A load is live (its session runs).
    public var loaded: Bool
    public var generation: UInt64
    public var dir: String
    public var files: [String]
    /// This reload replaced the live config.
    public var applied: Bool
    /// Why the last reload kept the previous config.
    public var diagnostics: [Diagnostic]
    public var actions: [Action]
    public var keys: [Key]
    public var modes: [Mode]
    public var removals: [Removal]
}

/// `script-config-status`: the live config, loading nothing.
public struct ScriptConfigStatusRequest: DaemonRequest {
    public typealias Response = ScriptConfigReport
    public static let command = "script-config-status"
    public static let requiredCapability: String? = DaemonCapabilities.shared.scriptConfig

    public init() {}
}

/// `script-config-reload`: runs the config scripts again. The new config
/// replaces the live one only when every file ran; then the daemon emits
/// `script-config-changed`.
public struct ScriptConfigReloadRequest: DaemonRequest {
    public typealias Response = ScriptConfigReport
    public static let command = "script-config-reload"
    public static let requiredCapability: String? = DaemonCapabilities.shared.scriptConfig

    public init() {}
}

/// `script-action-run`: runs a config script's `user.*` action. `context`
/// tells the script who ran it (`origin`) and the focused objects' public
/// ids (`workspace`, `pane`, `tab`, `terminal`).
public struct ScriptActionRunRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public var value: JSONValue?
    }

    public static let command = "script-action-run"
    public static let requiredCapability: String? = DaemonCapabilities.shared.scriptConfig

    public var action: String
    public var args: [String: JSONValue]
    public var context: [String: JSONValue]

    public init(action: String, args: [String: JSONValue], context: [String: JSONValue]) {
        self.action = action
        self.args = args
        self.context = context
    }

    enum CodingKeys: String, CodingKey { case action }
}

extension ScriptActionRunRequest: VerbatimFieldsRequest {
    var verbatimFields: [String: JSONValue] { ["args": .object(args), "context": .object(context)] }
}
