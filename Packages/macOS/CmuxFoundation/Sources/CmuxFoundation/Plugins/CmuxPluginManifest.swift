import Foundation

/// A parsed and validated `cmux-plugin.toml`.
///
/// The file format is shared with the cmux-tui plugin manager: `[plugin]`
/// carries identity, `[run]` and `[build]` carry the sidebar and agent
/// commands. The app adds `kind = "extension"`, whose `[[actions]]` become
/// command-palette actions and whose `[[events]]` become automation rules.
public struct CmuxPluginManifest: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case sidebar
        case agent
        case `extension`
    }

    public static let fileName = "cmux-plugin.toml"
    /// Manifests are small; a larger file is rejected before parsing.
    public static let maximumFileBytes = 64 * 1024
    static let maximumActions = 64
    static let maximumEvents = 64
    static let maximumArguments = 64

    public let name: String
    public let kind: Kind
    public let version: String?
    public let description: String?
    public let platforms: [String]?
    public let runCommand: [String]?
    public let buildCommand: [String]?
    public let actions: [CmuxPluginAction]
    public let events: [CmuxPluginEventHook]

    public init(
        name: String,
        kind: Kind,
        version: String? = nil,
        description: String? = nil,
        platforms: [String]? = nil,
        runCommand: [String]? = nil,
        buildCommand: [String]? = nil,
        actions: [CmuxPluginAction] = [],
        events: [CmuxPluginEventHook] = []
    ) {
        self.name = name
        self.kind = kind
        self.version = version
        self.description = description
        self.platforms = platforms
        self.runCommand = runCommand
        self.buildCommand = buildCommand
        self.actions = actions
        self.events = events
    }

    /// Parses and validates manifest text. Unknown tables and keys are
    /// rejected, matching the cmux-tui manager, so a typo such as `args`
    /// for `argv` fails at install time instead of silently doing nothing.
    public static func parse(_ text: String) throws -> CmuxPluginManifest {
        guard text.utf8.count <= maximumFileBytes else {
            throw CmuxPluginManifestError("manifest is larger than \(maximumFileBytes / 1024) KiB")
        }
        let document: [String: CmuxPluginTOMLValue]
        do {
            document = try CmuxPluginTOMLParser().parse(text)
        } catch let error as CmuxPluginTOMLError {
            throw CmuxPluginManifestError("invalid TOML at \(error.description)")
        }
        var reader = TableReader(document, path: "manifest")
        let pluginTable = try reader.requiredTable("plugin")
        let runTable = try reader.optionalTable("run")
        let buildTable = try reader.optionalTable("build")
        let actionTables = try reader.optionalTableArray("actions")
        let eventTables = try reader.optionalTableArray("events")
        try reader.finish()

        var plugin = TableReader(pluginTable, path: "[plugin]")
        let name = try plugin.requiredString("name")
        let kindName = try plugin.requiredString("kind")
        let version = try plugin.optionalString("version")
        let description = try plugin.optionalString("description")
        let platforms = try plugin.optionalStringArray("platforms")
        try plugin.finish()

        try validateName(name, label: "plugin.name")
        guard let kind = Kind(rawValue: kindName) else {
            throw CmuxPluginManifestError("plugin.kind must be sidebar, agent, or extension")
        }
        if let platforms {
            let allowed: Set<String> = ["macos", "linux", "windows"]
            guard !platforms.isEmpty,
                  platforms.allSatisfy(allowed.contains),
                  Set(platforms).count == platforms.count else {
                throw CmuxPluginManifestError("plugin.platforms must list macos, linux, or windows without duplicates")
            }
        }

        let runCommand = try runTable.map { table -> [String] in
            var run = TableReader(table, path: "[run]")
            let command = try run.requiredArgv("command")
            try run.finish()
            return command
        }
        let buildCommand = try buildTable.map { table -> [String] in
            var build = TableReader(table, path: "[build]")
            let command = try build.requiredArgv("command")
            try build.finish()
            return command
        }

        let actions = try actionTables.enumerated().map { index, table in
            try CmuxPluginAction.parse(table, path: "actions[\(index)]")
        }
        let events = try eventTables.enumerated().map { index, table in
            try CmuxPluginEventHook.parse(table, path: "events[\(index)]")
        }

        switch kind {
        case .sidebar, .agent:
            guard runCommand != nil else {
                throw CmuxPluginManifestError("\(kind.rawValue) plugins require [run].command")
            }
            guard actions.isEmpty, events.isEmpty else {
                throw CmuxPluginManifestError("[[actions]] and [[events]] require kind = \"extension\"")
            }
        case .extension:
            guard !actions.isEmpty || !events.isEmpty else {
                throw CmuxPluginManifestError("extension plugins must declare at least one [[actions]] or [[events]] entry")
            }
            guard actions.count <= maximumActions, events.count <= maximumEvents else {
                throw CmuxPluginManifestError("extension plugins may declare at most \(maximumActions) actions and \(maximumEvents) events")
            }
            var seen = Set<String>()
            for action in actions where !seen.insert(action.id).inserted {
                throw CmuxPluginManifestError("duplicate action id '\(action.id)'")
            }
        }

        return CmuxPluginManifest(
            name: name,
            kind: kind,
            version: version,
            description: description,
            platforms: platforms,
            runCommand: runCommand,
            buildCommand: buildCommand,
            actions: actions,
            events: events
        )
    }

    /// Whether the manifest allows this Mac. An absent list means every platform.
    public var supportsMacOS: Bool {
        platforms?.contains("macos") ?? true
    }

    /// Names follow the cmux-tui rule: `[a-z0-9_-]+`, at most 64 bytes. The
    /// same rule keeps `plugin.<name>.<action>` unambiguous.
    static func validateName(_ value: String, label: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !value.isEmpty,
              value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CmuxPluginManifestError("\(label) must match [a-z0-9-_]+ and be at most 64 bytes")
        }
    }
}

/// A palette action declared by `[[actions]]`.
public struct CmuxPluginAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let argv: [String]
    /// Default shortcut in cmux.json syntax (`cmd+shift+y`). The app ignores
    /// it when it is invalid or already bound to a cmux shortcut.
    public let shortcut: String?
    public let palette: Bool
    public let timeoutSeconds: Int?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        argv: [String],
        shortcut: String? = nil,
        palette: Bool = true,
        timeoutSeconds: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.argv = argv
        self.shortcut = shortcut
        self.palette = palette
        self.timeoutSeconds = timeoutSeconds
    }

    static func parse(_ table: [String: CmuxPluginTOMLValue], path: String) throws -> CmuxPluginAction {
        var reader = TableReader(table, path: path)
        let id = try reader.requiredString("id")
        let title = try reader.requiredString("title")
        let subtitle = try reader.optionalString("subtitle")
        let keywords = try reader.optionalStringArray("keywords") ?? []
        let argv = try reader.requiredArgv("argv")
        let shortcut = try reader.optionalString("shortcut")
        let palette = try reader.optionalBool("palette") ?? true
        let timeout = try reader.optionalTimeout()
        try reader.finish()
        try CmuxPluginManifest.validateName(id, label: "\(path).id")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmuxPluginManifestError("\(path).title must not be empty")
        }
        return CmuxPluginAction(
            id: id,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            argv: argv,
            shortcut: shortcut,
            palette: palette,
            timeoutSeconds: timeout
        )
    }
}

/// A command run on a cmux event, declared by `[[events]]`.
public struct CmuxPluginEventHook: Equatable, Sendable {
    /// Exact event name or `*` prefix/suffix wildcard, as in automations.json.
    public let event: String
    public let argv: [String]
    public let timeoutSeconds: Int?

    public init(event: String, argv: [String], timeoutSeconds: Int? = nil) {
        self.event = event
        self.argv = argv
        self.timeoutSeconds = timeoutSeconds
    }

    static func parse(_ table: [String: CmuxPluginTOMLValue], path: String) throws -> CmuxPluginEventHook {
        var reader = TableReader(table, path: path)
        let event = try reader.requiredString("event")
        let argv = try reader.requiredArgv("argv")
        let timeout = try reader.optionalTimeout()
        try reader.finish()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-*"))
        guard !event.isEmpty,
              event.utf8.count <= 128,
              event.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }),
              !event.dropFirst().dropLast().contains("*") else {
            throw CmuxPluginManifestError("\(path).event must be an event name such as workspace.created")
        }
        return CmuxPluginEventHook(event: event, argv: argv, timeoutSeconds: timeout)
    }
}

public struct CmuxPluginManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Reads typed keys from one table and rejects keys nobody asked for.
private struct TableReader {
    private let table: [String: CmuxPluginTOMLValue]
    private let path: String
    private var consumed = Set<String>()

    init(_ table: [String: CmuxPluginTOMLValue], path: String) {
        self.table = table
        self.path = path
    }

    mutating func finish() throws {
        if let unknown = table.keys.filter({ !consumed.contains($0) }).sorted().first {
            throw CmuxPluginManifestError("\(path) has unknown key '\(unknown)'")
        }
    }

    private mutating func take(_ key: String) -> CmuxPluginTOMLValue? {
        consumed.insert(key)
        return table[key]
    }

    mutating func requiredTable(_ key: String) throws -> [String: CmuxPluginTOMLValue] {
        guard let table = try optionalTable(key) else {
            throw CmuxPluginManifestError("\(path) is missing [\(key)]")
        }
        return table
    }

    mutating func optionalTable(_ key: String) throws -> [String: CmuxPluginTOMLValue]? {
        switch take(key) {
        case nil:
            return nil
        case .table(let table)?:
            return table
        default:
            throw CmuxPluginManifestError("\(key) must be a table")
        }
    }

    mutating func optionalTableArray(_ key: String) throws -> [[String: CmuxPluginTOMLValue]] {
        switch take(key) {
        case nil:
            return []
        case .array(let values)?:
            return try values.map { value in
                guard case .table(let table) = value else {
                    throw CmuxPluginManifestError("\(key) must be written as [[\(key)]] tables")
                }
                return table
            }
        default:
            throw CmuxPluginManifestError("\(key) must be written as [[\(key)]] tables")
        }
    }

    mutating func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw CmuxPluginManifestError("\(path) is missing \(key)")
        }
        return value
    }

    mutating func optionalString(_ key: String) throws -> String? {
        switch take(key) {
        case nil:
            return nil
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            throw CmuxPluginManifestError("\(path).\(key) must be a string")
        }
    }

    mutating func optionalBool(_ key: String) throws -> Bool? {
        switch take(key) {
        case nil:
            return nil
        case .bool(let value)?:
            return value
        default:
            throw CmuxPluginManifestError("\(path).\(key) must be true or false")
        }
    }

    mutating func optionalStringArray(_ key: String) throws -> [String]? {
        switch take(key) {
        case nil:
            return nil
        case .array(let values)?:
            return try values.map { value in
                guard case .string(let string) = value else {
                    throw CmuxPluginManifestError("\(path).\(key) must be an array of strings")
                }
                return string
            }
        default:
            throw CmuxPluginManifestError("\(path).\(key) must be an array of strings")
        }
    }

    /// Argument vectors are passed to the process verbatim, never through a
    /// shell, so each element is kept exactly as written.
    mutating func requiredArgv(_ key: String) throws -> [String] {
        guard let argv = try optionalStringArray(key),
              let first = argv.first,
              !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmuxPluginManifestError("\(path).\(key) must be a non-empty array of strings")
        }
        guard argv.count <= CmuxPluginManifest.maximumArguments,
              argv.allSatisfy({ !$0.unicodeScalars.contains("\u{0}") }) else {
            throw CmuxPluginManifestError("\(path).\(key) has too many or invalid arguments")
        }
        return argv
    }

    mutating func optionalTimeout() throws -> Int? {
        switch take("timeout_seconds") {
        case nil:
            return nil
        case .integer(let value)? where (1...300).contains(value):
            return value
        default:
            throw CmuxPluginManifestError("\(path).timeout_seconds must be an integer from 1 to 300")
        }
    }
}
