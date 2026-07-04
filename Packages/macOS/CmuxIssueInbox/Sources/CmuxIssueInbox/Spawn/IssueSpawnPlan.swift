public import Foundation

/// Workspace spawn plan for an Issue Inbox row.
public struct IssueSpawnPlan: Codable, Equatable, Sendable {
    /// Optional custom workspace layout.
    public var layout: IssueSpawnLayoutNode?
    /// Optional single-terminal startup command when no custom layout is needed.
    public var initialCommand: String?
    /// Resolved agent choice.
    public var agent: IssueSpawnAgent

    /// Creates a workspace spawn plan.
    ///
    /// - Parameters:
    ///   - layout: Optional custom workspace layout.
    ///   - initialCommand: Optional single-terminal startup command.
    ///   - agent: Resolved agent choice.
    public init(
        layout: IssueSpawnLayoutNode? = nil,
        initialCommand: String? = nil,
        agent: IssueSpawnAgent
    ) {
        self.layout = layout
        self.initialCommand = initialCommand
        self.agent = agent
    }
}

/// Codable layout node matching cmux workspace layout JSON.
public indirect enum IssueSpawnLayoutNode: Codable, Equatable, Sendable {
    /// A pane with one or more surfaces.
    case pane(IssueSpawnPaneDefinition)
    /// A split with exactly two children.
    case split(IssueSpawnSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    /// Decodes a layout node.
    ///
    /// - Parameter decoder: Source decoder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pane) {
            self = .pane(try container.decode(IssueSpawnPaneDefinition.self, forKey: .pane))
        } else {
            self = .split(try IssueSpawnSplitDefinition(from: decoder))
        }
    }

    /// Encodes a layout node.
    ///
    /// - Parameter encoder: Target encoder.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

/// Codable split definition matching cmux workspace layout JSON.
public struct IssueSpawnSplitDefinition: Codable, Equatable, Sendable {
    /// Split direction. `horizontal` creates left and right panes, `vertical` creates top and bottom panes.
    public var direction: IssueSpawnSplitDirection
    /// Divider position.
    public var split: Double?
    /// Exactly two child nodes.
    public var children: [IssueSpawnLayoutNode]

    /// Creates a split definition.
    ///
    /// - Parameters:
    ///   - direction: Split direction.
    ///   - split: Divider position.
    ///   - children: Exactly two child nodes.
    public init(
        direction: IssueSpawnSplitDirection,
        split: Double? = nil,
        children: [IssueSpawnLayoutNode]
    ) {
        self.direction = direction
        self.split = split
        self.children = children
    }
}

/// Split direction values accepted by cmux workspace layout JSON.
public enum IssueSpawnSplitDirection: String, Codable, Equatable, Sendable {
    /// Left and right split.
    case horizontal
    /// Top and bottom split.
    case vertical
}

/// Codable pane definition matching cmux workspace layout JSON.
public struct IssueSpawnPaneDefinition: Codable, Equatable, Sendable {
    /// Surfaces in the pane.
    public var surfaces: [IssueSpawnSurfaceDefinition]

    /// Creates a pane definition.
    ///
    /// - Parameter surfaces: Surfaces in the pane.
    public init(surfaces: [IssueSpawnSurfaceDefinition]) {
        self.surfaces = surfaces
    }
}

/// Codable surface definition matching cmux workspace layout JSON.
public struct IssueSpawnSurfaceDefinition: Codable, Equatable, Sendable {
    /// Surface type.
    public var type: IssueSpawnSurfaceType
    /// Optional display name.
    public var name: String?
    /// Optional terminal command.
    public var command: String?
    /// Optional working directory.
    public var cwd: String?
    /// Optional browser URL.
    public var url: String?
    /// Whether this surface should receive focus.
    public var focus: Bool?

    /// Creates a surface definition.
    ///
    /// - Parameters:
    ///   - type: Surface type.
    ///   - name: Optional display name.
    ///   - command: Optional terminal command.
    ///   - cwd: Optional working directory.
    ///   - url: Optional browser URL.
    ///   - focus: Whether this surface should receive focus.
    public init(
        type: IssueSpawnSurfaceType,
        name: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        url: String? = nil,
        focus: Bool? = nil
    ) {
        self.type = type
        self.name = name
        self.command = command
        self.cwd = cwd
        self.url = url
        self.focus = focus
    }
}

/// Surface type values accepted by cmux workspace layout JSON.
public enum IssueSpawnSurfaceType: String, Codable, Equatable, Sendable {
    /// Terminal surface.
    case terminal
    /// Browser surface.
    case browser
}

/// Spawn plan construction for Issue Inbox rows.
extension IssueSpawnPlan {
    /// Builds a workspace spawn plan.
    ///
    /// - Parameters:
    ///   - item: Issue row being spawned.
    ///   - sourceConfig: Source configuration for the issue, if available.
    ///   - workingDirectory: Workspace working directory.
    ///   - requestedAgent: Caller-selected agent, if any.
    /// - Returns: Spawn plan with optional layout and startup command.
    public static func build(
        item: IssueInboxItem,
        sourceConfig: IssueInboxSourceConfig?,
        workingDirectory: String?,
        requestedAgent: IssueSpawnAgent?
    ) -> IssueSpawnPlan {
        let spawn = sourceConfig?.spawn
        let agent = requestedAgent ?? spawn?.defaultAgent ?? .none
        let agentCommand = command(
            agent: agent,
            template: spawn?.agentCommandTemplate,
            prompt: prompt(for: item),
            item: item
        )
        let webURL = trimmed(spawn?.webURL)
        let devServerCommand = trimmed(spawn?.devServerCommand)
        let cwd = trimmed(workingDirectory)

        let left = terminalPane(
            name: "Issue Agent",
            command: agentCommand,
            cwd: cwd,
            focus: true
        )
        let right = rightNode(
            webURL: webURL,
            devServerCommand: devServerCommand,
            cwd: cwd
        )

        if let right {
            return IssueSpawnPlan(
                layout: .split(IssueSpawnSplitDefinition(
                    direction: .horizontal,
                    split: 0.5,
                    children: [left, right]
                )),
                agent: agent
            )
        }

        return IssueSpawnPlan(
            initialCommand: agentCommand,
            agent: agent
        )
    }

    /// Builds the human-readable issue prompt passed to agents.
    ///
    /// - Parameter item: Issue row being spawned.
    /// - Returns: Prompt text.
    public static func prompt(for item: IssueInboxItem) -> String {
        let providerName: String
        let reference: String
        switch item.provider {
        case .github:
            providerName = "GitHub issue"
            reference = "\(item.repoOrProject)#\(item.number)"
        case .linear:
            providerName = "Linear issue"
            reference = "\(item.repoOrProject) \(item.number)"
        }
        return "Work on \(providerName) \(reference): \(item.title) (\(item.sourceURL.absoluteString))"
    }

    /// Shell-quotes a string as one POSIX single-quoted argument.
    ///
    /// - Parameter value: Raw value.
    /// - Returns: Single-quoted shell argument.
    public static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func command(
        agent: IssueSpawnAgent,
        template: String?,
        prompt: String,
        item: IssueInboxItem
    ) -> String? {
        guard agent != .none else { return nil }
        if let template = trimmed(template) {
            return template
                .replacingOccurrences(of: "{prompt}", with: shellQuoted(prompt))
                .replacingOccurrences(of: "{url}", with: shellQuoted(item.sourceURL.absoluteString))
                .replacingOccurrences(of: "{number}", with: shellQuoted(item.number))
                .replacingOccurrences(of: "{title}", with: shellQuoted(item.title))
        }
        return "\(agent.rawValue) \(shellQuoted(prompt))"
    }

    private static func rightNode(
        webURL: String?,
        devServerCommand: String?,
        cwd: String?
    ) -> IssueSpawnLayoutNode? {
        switch (webURL, devServerCommand) {
        case let (.some(url), .some(command)):
            return .split(IssueSpawnSplitDefinition(
                direction: .vertical,
                split: 0.5,
                children: [
                    browserPane(url: url),
                    terminalPane(name: "Dev Server", command: command, cwd: cwd, focus: false),
                ]
            ))
        case let (.some(url), .none):
            return browserPane(url: url)
        case let (.none, .some(command)):
            return terminalPane(name: "Dev Server", command: command, cwd: cwd, focus: false)
        case (.none, .none):
            return nil
        }
    }

    private static func terminalPane(
        name: String,
        command: String?,
        cwd: String?,
        focus: Bool
    ) -> IssueSpawnLayoutNode {
        .pane(IssueSpawnPaneDefinition(surfaces: [
            IssueSpawnSurfaceDefinition(
                type: .terminal,
                name: name,
                command: command,
                cwd: cwd,
                focus: focus
            ),
        ]))
    }

    private static func browserPane(url: String) -> IssueSpawnLayoutNode {
        .pane(IssueSpawnPaneDefinition(surfaces: [
            IssueSpawnSurfaceDefinition(
                type: .browser,
                name: "Project Site",
                url: url
            ),
        ]))
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
