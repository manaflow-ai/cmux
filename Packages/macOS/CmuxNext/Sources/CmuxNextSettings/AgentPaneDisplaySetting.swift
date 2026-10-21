/// The agent chat's look as the chat page gets it (the `display` page event; plans/cmux-next/chat-display-settings-DESIGN.md):
/// every `agentPane.display.*` value cmux.json holds that its row accepts, and the Markdown viewer
/// values the chat follows when its own is unset (`markdown.font.preset`, `markdown.code.family`,
/// `markdown.code.scale`), as one flat map by dotted key. The page resolves which wins
/// (webviews/src/agent-session/acpmux/chatDisplay.ts).
///
/// ```swift
/// let display = AgentPaneDisplaySetting(fileRoot: settings.fileRoot)
/// view.pushDisplay(display)
/// ```
public nonisolated struct AgentPaneDisplaySetting: Sendable, Hashable {
    /// The Markdown viewer keys the chat follows.
    public static let followedMarkdownPaths: [[String]] = [
        ["markdown", "font", "preset"], ["markdown", "code", "family"], ["markdown", "code", "scale"],
    ]

    /// The accepted values by dotted key.
    public var values: [String: JSONValue]

    /// A look from values already checked.
    ///
    /// - Parameter values: Values by dotted key; empty is the default look.
    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }

    /// No value: the chat's default look.
    public static let fallback = AgentPaneDisplaySetting()

    /// Reads the chat's keys and the followed Markdown viewer keys from a cmux.json root, keeping
    /// each value its row accepts and dropping the rest.
    ///
    /// - Parameter fileRoot: The settings file's root object.
    public init(fileRoot: JSONValue) {
        var values: [String: JSONValue] = [:]
        let followed = Set(Self.followedMarkdownPaths.map { $0.joined(separator: ".") })
        let rows = AgentPaneDisplaySettingsSchema.descriptors
            + MarkdownViewerSettingsSchema.descriptors.filter { followed.contains($0.id) }
        for descriptor in rows {
            guard let value = fileRoot.value(at: descriptor.path), value != .null, descriptor.accepts(value) else { continue }
            values[descriptor.id] = value
        }
        self.init(values: values)
    }

    /// The page's value: the map as a JSON object.
    public var pageValue: JSONValue { .object(values) }

    /// The key path of a dotted chat key the page may write (`agentPane.display.*`), nil for any other key.
    ///
    /// - Parameter key: A dotted key such as `agentPane.display.font.size`.
    /// - Returns: The path to write, or nil when the page may not write `key`.
    public static func writablePath(_ key: String) -> [String]? {
        guard AgentPaneDisplaySettingsSchema.keys.contains(key) else { return nil }
        return key.split(separator: ".").map(String.init)
    }
}
