import Bonsplit
import CmuxFoundation
import Combine
import CryptoKit
import Foundation
import CmuxSettings

extension CodingUserInfoKey {
    static let cmuxWorkspaceColorDefaults = CodingUserInfoKey(rawValue: "cmuxWorkspaceColorDefaults")!
}

struct CmuxConfigFile: Codable, Sendable {
    var actions: [String: CmuxConfigActionDefinition]
    var ui: CmuxConfigUIDefinition?
    var notifications: CmuxNotificationConfigDefinition?
    var agentChat: CmuxAgentChatConfigDefinition?
    var newWorkspaceCommand: String?
    var surfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
    var commands: [CmuxCommandDefinition]
    var vault: CmuxVaultConfigDefinition?
    var workspaceGroups: CmuxConfigWorkspaceGroupsDefinition?

    private enum CodingKeys: String, CodingKey {
        case actions, ui, notifications, agentChat, newWorkspaceCommand, surfaceTabBarButtons, commands, vault, workspaceGroups
    }

    init(
        actions: [String: CmuxConfigActionDefinition] = [:],
        ui: CmuxConfigUIDefinition? = nil,
        notifications: CmuxNotificationConfigDefinition? = nil,
        agentChat: CmuxAgentChatConfigDefinition? = nil,
        newWorkspaceCommand: String? = nil,
        surfaceTabBarButtons: [CmuxSurfaceTabBarButton]? = nil,
        commands: [CmuxCommandDefinition] = [],
        vault: CmuxVaultConfigDefinition? = nil,
        workspaceGroups: CmuxConfigWorkspaceGroupsDefinition? = nil
    ) {
        self.actions = actions
        self.ui = ui
        self.notifications = notifications
        self.agentChat = agentChat
        self.newWorkspaceCommand = newWorkspaceCommand
        self.surfaceTabBarButtons = surfaceTabBarButtons
        self.commands = commands
        self.vault = vault
        self.workspaceGroups = workspaceGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedActions = try container.decodeIfPresent(
            [String: CmuxConfigActionDefinition].self,
            forKey: .actions
        ) ?? [:]
        actions = try Self.normalizedActions(
            decodedActions,
            codingPath: decoder.codingPath + [CodingKeys.actions]
        )
        ui = try container.decodeIfPresent(CmuxConfigUIDefinition.self, forKey: .ui)
        notifications = try container.decodeIfPresent(CmuxNotificationConfigDefinition.self, forKey: .notifications)
        agentChat = try container.decodeIfPresent(CmuxAgentChatConfigDefinition.self, forKey: .agentChat)

        if let rawNewWorkspaceCommand = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCommand) {
            let trimmed = rawNewWorkspaceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.newWorkspaceCommand],
                        debugDescription: "newWorkspaceCommand must not be blank"
                    )
                )
            }
            newWorkspaceCommand = trimmed
        } else {
            newWorkspaceCommand = nil
        }

        let rootSurfaceButtons = try container.decodeIfPresent(
            [CmuxSurfaceTabBarButton].self,
            forKey: .surfaceTabBarButtons
        )
        let configuredSurfaceButtons = ui?.surfaceTabBar?.buttons ?? rootSurfaceButtons
        if let configuredSurfaceButtons {
            surfaceTabBarButtons = try Self.validatedSurfaceTabBarButtons(
                configuredSurfaceButtons,
                codingPath: decoder.codingPath + [
                    ui?.surfaceTabBar?.buttons == nil ? CodingKeys.surfaceTabBarButtons : CodingKeys.ui
                ]
            )
        } else {
            surfaceTabBarButtons = nil
        }
        commands = try container.decodeIfPresent([CmuxCommandDefinition].self, forKey: .commands) ?? []
        vault = try container.decodeIfPresent(CmuxVaultConfigDefinition.self, forKey: .vault)
        workspaceGroups = try container.decodeIfPresent(
            CmuxConfigWorkspaceGroupsDefinition.self,
            forKey: .workspaceGroups
        )
    }

    private static func normalizedActions(
        _ decodedActions: [String: CmuxConfigActionDefinition],
        codingPath: [CodingKey]
    ) throws -> [String: CmuxConfigActionDefinition] {
        var actions: [String: CmuxConfigActionDefinition] = [:]
        var canonicalIDs: [String: String] = [:]
        for (rawID, action) in decodedActions {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions keys must not be blank"
                    )
                )
            }
            if id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "action IDs must not contain control or format characters"
                    )
                )
            }
            if actions[id] != nil {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate ids"
                    )
                )
            }
            let canonicalID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
            if let existingID = canonicalIDs[canonicalID] {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate aliases for '\(canonicalID)' (found '\(existingID)' and '\(id)')"
                    )
                )
            }
            canonicalIDs[canonicalID] = id
            actions[id] = action
        }
        return actions
    }

    private static func validatedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        codingPath: [CodingKey]
    ) throws -> [CmuxSurfaceTabBarButton] {
        var seen = Set<String>()
        for button in buttons {
            if !seen.insert(button.id).inserted {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "surface tab bar buttons must not contain duplicate ids"
                    )
                )
            }
        }
        return buttons
    }
}

/// Per-cwd customization for sidebar workspace groups. Keyed by the anchor
/// workspace's cwd. Keys containing `*` or `?` are matched as fnmatch globs;
/// otherwise they are path prefixes. Longest match wins. `~` is expanded.
struct CmuxConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    var byCwd: [String: CmuxConfigWorkspaceGroupEntry]?

    enum CodingKeys: String, CodingKey {
        case byCwd
    }
}

struct CmuxConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    var color: String?
    var icon: String?
    var contextMenu: [CmuxConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (the stored `workspaceGroups.newWorkspacePlacement` setting).
    var newWorkspacePlacement: String?
}

/// Resolved snapshot of a per-cwd workspace group entry, with the JSON key
/// normalized for matching and any `contextMenu` actions resolved against the
/// loaded action/command tables.
struct CmuxResolvedWorkspaceGroupConfig: Sendable, Equatable {
    let originalKey: String
    let normalizedKey: String
    let isGlob: Bool
    let color: String?
    let iconSymbol: String?
    let contextMenuItems: [CmuxResolvedConfigContextMenuItem]
    /// Parsed override for where the `+` button places its new workspace.
    /// nil means "fall through to the global default."
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
}

enum CmuxNotificationHooksMode: String, Codable, Sendable, Hashable {
    case append
    case replace
}

struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    var hooks: [CmuxNotificationHookDefinition]?
    var hooksMode: CmuxNotificationHooksMode?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
    }
}

struct CmuxNotificationHookDefinition: Codable, Sendable, Hashable {
    static let defaultTimeoutSeconds: TimeInterval = 20

    var id: String
    var command: String
    var timeoutSeconds: TimeInterval?
    var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case timeoutSeconds
        case enabled
    }

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try Self.requiredTrimmedString(forKey: .id, in: container)
        let decodedCommand = try Self.requiredTrimmedString(forKey: .command, in: container)
        let decodedTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
        if let decodedTimeout, !decodedTimeout.isFinite || decodedTimeout <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .timeoutSeconds,
                in: container,
                debugDescription: "timeoutSeconds must be greater than 0"
            )
        }

        id = decodedID
        command = decodedCommand
        timeoutSeconds = decodedTimeout
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(enabled, forKey: .enabled)
    }

    var resolvedTimeoutSeconds: TimeInterval {
        timeoutSeconds ?? Self.defaultTimeoutSeconds
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return value
    }
}

struct CmuxResolvedNotificationHook: Sendable, Hashable {
    let id: String
    let command: String
    let timeoutSeconds: TimeInterval
    let sourcePath: String?
    let cwd: String
    let trustDescriptor: CmuxActionTrustDescriptor?

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval,
        sourcePath: String?,
        cwd: String,
        trustDescriptor: CmuxActionTrustDescriptor? = nil
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.sourcePath = sourcePath
        self.cwd = cwd
        self.trustDescriptor = trustDescriptor
    }

    static func == (lhs: CmuxResolvedNotificationHook, rhs: CmuxResolvedNotificationHook) -> Bool {
        lhs.id == rhs.id &&
            lhs.command == rhs.command &&
            lhs.timeoutSeconds == rhs.timeoutSeconds &&
            lhs.sourcePath == rhs.sourcePath &&
            lhs.cwd == rhs.cwd &&
            lhs.trustDescriptor?.fingerprint == rhs.trustDescriptor?.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(command)
        hasher.combine(timeoutSeconds)
        hasher.combine(sourcePath)
        hasher.combine(cwd)
        hasher.combine(trustDescriptor?.fingerprint)
    }
}

enum CmuxConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    case currentTerminal
    case newTabInCurrentPane

    static let defaultForActions: CmuxConfigTerminalCommandTarget = .newTabInCurrentPane
}

/// Agent launched by an `agent` action. Known kinds carry presentation
/// defaults (icon, display title); any other CLI name decodes as `.custom`
/// so new agents never require an app change.
enum CmuxConfigAgentKind: Sendable, Hashable {
    case codex
    case claudeCode
    case opencode
    case custom(String)

    var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        case .opencode:
            return "opencode"
        case .custom(let name):
            return name
        }
    }

    var defaultIcon: CmuxButtonIcon {
        switch self {
        case .codex:
            return .symbol("sparkles")
        case .claudeCode:
            return .symbol("brain.head.profile")
        case .opencode:
            return .symbol("chevron.left.forwardslash.chevron.right")
        case .custom:
            return .symbol("terminal")
        }
    }
}

extension CmuxConfigAgentKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "codex":
            self = .codex
        case "claude", "claudeCode", "claude-code":
            self = .claudeCode
        case "opencode", "openCode", "open-code":
            self = .opencode
        default:
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "agent must be a single command name with no whitespace; put flags in 'args'"
                    )
                )
            }
            self = .custom(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(commandName)
    }
}

enum CmuxButtonIcon: Codable, Sendable, Hashable {
    case symbol(String)
    case emoji(String, scale: Double = 1)
    case imagePath(String)

    var symbolName: String {
        if case .symbol(let name) = self {
            return name
        }
        return "questionmark.circle"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case value
        case path
        case scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            self = .symbol(try Self.trimmedString(forKey: .name, in: container))
        case "emoji":
            self = .emoji(
                try Self.trimmedString(forKey: .value, in: container),
                scale: try Self.emojiScale(in: container)
            )
        case "image", "file":
            self = .imagePath(try Self.trimmedString(forKey: .path, in: container))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown icon type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try container.encode("symbol", forKey: .type)
            try container.encode(name, forKey: .name)
        case .emoji(let value, let scale):
            try container.encode("emoji", forKey: .type)
            try container.encode(value, forKey: .value)
            if scale != 1 {
                try container.encode(scale, forKey: .scale)
            }
        case .imagePath(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    func bonsplitIcon(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalImage: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton.Icon {
        switch self {
        case .symbol(let name):
            return .systemImage(name)
        case .emoji(let value, let scale):
            return .emoji(value, scale: scale)
        case .imagePath(let path):
            guard let preparedImage = Self.preparedImageAsset(
                path,
                relativeToConfig: configSourcePath,
                globalConfigPath: globalConfigPath
            ) else {
                NSLog("[CmuxConfig] icon image path is not allowed: %@", path)
                return .systemImage("questionmark.circle")
            }
            if preparedImage.isProjectLocal && !allowProjectLocalImage {
                return .systemImage("lock.fill")
            }
            return .imageData(preparedImage.data)
        }
    }

    func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
        guard case .imagePath(let path) = self,
              let preparedImage = Self.preparedImageAsset(
                  path,
                  relativeToConfig: configSourcePath,
                  globalConfigPath: globalConfigPath
              ),
              preparedImage.isProjectLocal else {
            return nil
        }
        return preparedImage.fingerprint
    }

    func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> CmuxButtonIcon {
        guard case .imagePath(let path) = self else { return self }
        return .imagePath(Self.resolvePath(path, relativeToConfig: configSourcePath))
    }

    private static let maxImageBytes = 1_000_000

    private static func emojiScale(in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        guard scale.isFinite, scale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scale,
                in: container,
                debugDescription: "Emoji icon scale must be a positive number"
            )
        }
        return scale
    }

    private struct PreparedImageAsset {
        let data: Data
        let fingerprint: String
        let isProjectLocal: Bool
    }

    private static func looksLikeSVGPath(_ value: String) -> Bool {
        (value as NSString).pathExtension.lowercased() == "svg"
    }

    private static func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
    }

    private static func resolvePath(_ path: String, relativeToConfig configSourcePath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        guard let configSourcePath else { return expanded }
        let base = (configSourcePath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(expanded)
    }

    private static func safeResolvedImagePath(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("http://"),
              !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }

        let isGlobal = configSourcePath == nil || configSourcePath == globalConfigPath
        if !isGlobal {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !(expanded as NSString).isAbsolutePath,
                  expanded == trimmed else {
                return nil
            }
        }

        let resolvedPath = resolvePath(trimmed, relativeToConfig: configSourcePath)
        guard !resolvedPath.isEmpty else { return nil }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard !isGlobal, let configSourcePath else {
            return standardizedPath
        }

        let allowedRoot = projectRoot(forConfigPath: configSourcePath)
        let resolvedURL = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    private static func preparedImageAsset(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> PreparedImageAsset? {
        guard let resolvedPath = safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            NSLog("[CmuxConfig] icon image does not exist: %@", resolvedPath)
            return nil
        }
        guard data.count <= maxImageBytes else {
            NSLog("[CmuxConfig] icon image is too large: %@", resolvedPath)
            return nil
        }
        if looksLikeSVGPath(resolvedPath), !isSafeSVG(data: data) {
            NSLog("[CmuxConfig] icon SVG contains unsupported content: %@", resolvedPath)
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedImageAsset(data: data, fingerprint: fingerprint, isProjectLocal: isProjectLocal)
    }

    static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private final class SVGSecurityInspector: NSObject, XMLParserDelegate {
        private var isSafe = true
        private var elementStack: [String] = []

        func parse(data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            let parsed = parser.parse()
            return parsed && isSafe
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let loweredName = elementName.lowercased()
            elementStack.append(loweredName)

            if loweredName == "script" || loweredName == "foreignobject" {
                markUnsafe(parser)
                return
            }

            for (name, value) in attributeDict {
                guard Self.isSafeSVGAttribute(name: name, value: value) else {
                    markUnsafe(parser)
                    return
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !elementStack.isEmpty else { return }
            elementStack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elementStack.last == "style" else { return }
            guard Self.isSafeSVGStyle(string) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard elementStack.last == "style",
                  let text = String(data: CDATABlock, encoding: .utf8) else {
                return
            }
            guard Self.isSafeSVGStyle(text) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            if target.lowercased() == "xml-stylesheet" {
                markUnsafe(parser)
            }
        }

        private func markUnsafe(_ parser: XMLParser) {
            isSafe = false
            parser.abortParsing()
        }

        private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
            let loweredName = name.lowercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredValue = trimmedValue.lowercased()

            if loweredName.hasPrefix("on") {
                return false
            }

            if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") {
                return true
            }

            if loweredName == "href" || loweredName == "xlink:href" {
                return isSafeSVGReference(trimmedValue)
            }

            if containsBlockedSVGValue(loweredValue) {
                return false
            }

            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }

            return true
        }

        private static func isSafeSVGStyle(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("@import"),
                  !containsBlockedSVGValue(loweredValue) else {
                return false
            }
            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(value)
            }
            return true
        }

        private static func isSafeSVGReference(_ value: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return true }
            if trimmedValue.hasPrefix("#") {
                return true
            }
            if trimmedValue.lowercased().hasPrefix("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }
            return false
        }

        private static func containsBlockedSVGValue(_ value: String) -> Bool {
            let blockedFragments = [
                "javascript:",
                "data:",
                "http://",
                "https://",
                "file://",
                "blob:"
            ]
            return blockedFragments.contains { value.contains($0) }
        }

        private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            var searchStart = loweredValue.startIndex

            while let range = loweredValue.range(
                of: "url(",
                options: [],
                range: searchStart..<loweredValue.endIndex
            ) {
                let contentStart = range.upperBound
                guard let closing = loweredValue[contentStart...].firstIndex(of: ")") else {
                    return false
                }

                var reference = String(loweredValue[contentStart..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if (reference.hasPrefix("\"") && reference.hasSuffix("\"")) ||
                    (reference.hasPrefix("'") && reference.hasSuffix("'")) {
                    reference.removeFirst()
                    reference.removeLast()
                }

                guard reference.hasPrefix("#") else {
                    return false
                }

                searchStart = loweredValue.index(after: closing)
            }

            return true
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

enum CmuxSurfaceTabBarButtonAction: Sendable, Hashable {
    case builtIn(CmuxSurfaceTabBarBuiltInAction)
    case command(String)
    case agent(CmuxConfigAgentKind, args: String?)
    case workspaceCommand(String)
    case workspace(CmuxWorkspaceDefinition, restart: CmuxRestartBehavior?)
    case actionReference(String)

    var defaultId: String {
        switch self {
        case .builtIn(let action):
            return action.configID
        case .command(let command):
            return "command." + Self.generatedCommandId(for: command)
        case .agent(let agent, _):
            return agent.commandName
        case .workspaceCommand(let commandName):
            return "workspaceCommand." + Self.generatedCommandId(for: commandName)
        case .workspace(let definition, _):
            return "workspace." + Self.generatedCommandId(for: definition.name ?? "workspace")
        case .actionReference(let identifier):
            return identifier
        }
    }

    var defaultIcon: String {
        defaultButtonIcon.symbolName
    }

    var defaultButtonIcon: CmuxButtonIcon {
        switch self {
        case .builtIn(let action):
            return .symbol(action.defaultIcon)
        case .command:
            return .symbol("terminal")
        case .agent(let agent, _):
            return agent.defaultIcon
        case .workspaceCommand, .workspace:
            return .symbol("rectangle.stack.badge.plus")
        case .actionReference:
            return .symbol("questionmark.circle")
        }
    }

    var terminalCommand: String? {
        switch self {
        case .command(let command):
            return command
        case .agent(let agent, let args):
            let trimmedArgs = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedArgs.isEmpty ? agent.commandName : "\(agent.commandName) \(trimmedArgs)"
        case .builtIn, .workspaceCommand, .workspace, .actionReference:
            return nil
        }
    }

    var workspaceCommandName: String? {
        if case .workspaceCommand(let name) = self {
            return name
        }
        return nil
    }

    /// Inline workspace payload for `type: "workspace"` actions.
    var inlineWorkspace: (definition: CmuxWorkspaceDefinition, restart: CmuxRestartBehavior?)? {
        if case .workspace(let definition, let restart) = self {
            return (definition, restart)
        }
        return nil
    }

    private static func generatedCommandId(for command: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? command
        return encoded.isEmpty ? "command" : encoded
    }
}

struct CmuxSurfaceTabBarButton: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case icon
        case tooltip
        case action
        case builtin
        case command
        case agent
        case args
        case type
        case commandName
        case name
        case workspace
        case restart
        case confirm
        case target
    }

    static let newTerminal = actionReference(CmuxSurfaceTabBarBuiltInAction.newTerminal.configID)
    static let newBrowser = actionReference(CmuxSurfaceTabBarBuiltInAction.newBrowser.configID)
    static let splitRight = actionReference(CmuxSurfaceTabBarBuiltInAction.splitRight.configID)
    static let splitDown = actionReference(CmuxSurfaceTabBarBuiltInAction.splitDown.configID)

    static let mobileConnect = actionReference(CmuxSurfaceTabBarBuiltInAction.mobileConnect.configID)

    static let defaults: [CmuxSurfaceTabBarButton] = [
        .newTerminal,
        .newBrowser,
        .splitRight,
        .splitDown
    ]

    static func builtIn(
        _ action: CmuxSurfaceTabBarBuiltInAction,
        id: String? = nil,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> CmuxSurfaceTabBarButton {
        CmuxSurfaceTabBarButton(
            id: id ?? action.configID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .builtIn(action),
            confirm: nil,
            terminalCommandTarget: nil
        )
    }

    static func actionReference(
        _ actionID: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil
    ) -> CmuxSurfaceTabBarButton {
        CmuxSurfaceTabBarButton(
            id: actionID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .actionReference(actionID)
        )
    }

    var command: String? {
        action.terminalCommand
    }

    var terminalCommand: String? {
        action.terminalCommand
    }

    var resolvedTerminalCommandTarget: CmuxConfigTerminalCommandTarget {
        terminalCommandTarget ?? CmuxConfigTerminalCommandTarget.defaultForActions
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Synthetic named command for inline `type: "workspace"` buttons/actions so
    /// execution and trust fingerprinting share one definition. Carries the
    /// button's `confirm` so explicit confirmation requests survive the wrap.
    var inlineWorkspaceSyntheticCommand: CmuxCommandDefinition? {
        guard let inline = action.inlineWorkspace else { return nil }
        return CmuxCommandDefinition(
            name: title ?? tooltip ?? inline.definition.name ?? id,
            restart: inline.restart,
            workspace: inline.definition,
            confirm: confirm
        )
    }

    func bonsplitActionButton(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalIcon: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton {
        let bonsplitAction: BonsplitConfiguration.SplitActionButton.Action = {
            switch action {
            case .builtIn(let builtIn):
                return builtIn.bonsplitAction ?? .custom(id)
            case .command, .agent, .workspaceCommand, .workspace, .actionReference:
                return .custom(id)
            }
        }()

        return BonsplitConfiguration.SplitActionButton(
            id: id,
            icon: (icon ?? action.defaultButtonIcon).bonsplitIcon(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: allowProjectLocalIcon
            ),
            tooltip: tooltip ?? title ?? terminalCommand,
            action: bonsplitAction
        )
    }

    init(
        id: String,
        title: String? = nil,
        icon: CmuxButtonIcon? = nil,
        tooltip: String? = nil,
        action: CmuxSurfaceTabBarButtonAction,
        confirm: Bool? = nil,
        terminalCommandTarget: CmuxConfigTerminalCommandTarget? = nil,
        actionSourcePath: String? = nil,
        iconSourcePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "surface tab bar button action must not be blank"
                    )
                )
            }
            self = CmuxSurfaceTabBarButton(
                id: CmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed,
                action: .actionReference(CmuxSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed)
            )
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitId = try Self.trimmedString(forKey: .id, in: container)
        let explicitTitle = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        let explicitIcon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        let explicitTooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        let rawAction = try Self.trimmedString(forKey: .action, in: container)
        let rawBuiltin = try Self.trimmedString(forKey: .builtin, in: container)
        let rawCommand = try Self.trimmedString(forKey: .command, in: container)
        let rawAgent = try container.decodeIfPresent(CmuxConfigAgentKind.self, forKey: .agent)
        let rawArgs = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        let rawCommandName = try Self.trimmedString(forKey: .commandName, in: container)
            ?? Self.trimmedString(forKey: .name, in: container)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(CmuxConfigTerminalCommandTarget.self, forKey: .target)
        actionSourcePath = nil
        iconSourcePath = nil

        let definedActionForms = [
            rawAction != nil,
            rawBuiltin != nil,
            rawCommand != nil,
            rawAgent != nil,
            rawType != nil
        ].filter(\.self).count
        if definedActionForms > 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define only one of 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        if let rawType {
            switch rawType {
            case "workspaceCommand":
                guard let rawCommandName else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspaceCommand surface tab bar buttons require commandName"
                        )
                    )
                }
                action = .workspaceCommand(rawCommandName)
            case "workspace":
                guard container.contains(.workspace) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspace surface tab bar buttons require a 'workspace' object"
                        )
                    )
                }
                let definition = try container.decode(CmuxWorkspaceDefinition.self, forKey: .workspace)
                let restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
                action = .workspace(definition, restart: restart)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown surface tab bar button type '\(rawType)'"
                )
            }
        } else if let rawCommand {
            action = .command(rawCommand)
        } else if let rawAgent {
            action = .agent(rawAgent, args: rawArgs)
        } else if let rawBuiltin {
            guard let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: rawBuiltin) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtin,
                    in: container,
                    debugDescription: "Unknown built-in surface tab bar action '\(rawBuiltin)'"
                )
            }
            action = .builtIn(builtIn)
        } else if let rawAction {
            action = .actionReference(rawAction)
        } else if let explicitId,
                  let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: explicitId) {
            action = .builtIn(builtIn)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        id = explicitId ?? action.defaultId
        title = explicitTitle
        icon = explicitIcon
        tooltip = explicitTooltip
    }

    func resolved(
        actions: [String: CmuxResolvedConfigAction],
        codingPath: [CodingKey]
    ) throws -> CmuxSurfaceTabBarButton {
        guard case .actionReference(let identifier) = action else {
            return self
        }

        let resolvedIdentifier = CmuxSurfaceTabBarBuiltInAction(configID: identifier)?.configID ?? identifier
        if let definition = actions[resolvedIdentifier] {
            return CmuxSurfaceTabBarButton(
                id: id,
                title: title ?? definition.title,
                icon: icon ?? definition.icon,
                tooltip: tooltip ?? definition.tooltip,
                action: definition.action,
                confirm: confirm ?? definition.confirm,
                terminalCommandTarget: terminalCommandTarget ?? definition.terminalCommandTarget,
                actionSourcePath: definition.actionSourcePath,
                iconSourcePath: icon == nil ? definition.iconSourcePath : iconSourcePath
            )
        }

        if let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return CmuxSurfaceTabBarButton(
                id: id,
                title: title,
                icon: icon,
                tooltip: tooltip,
                action: .builtIn(builtIn),
                confirm: confirm,
                terminalCommandTarget: terminalCommandTarget
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)

        switch action {
        case .builtIn(let builtIn):
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(args, forKey: .args)
        case .workspaceCommand(let commandName):
            try container.encode("workspaceCommand", forKey: .type)
            try container.encode(commandName, forKey: .commandName)
        case .workspace(let definition, let restart):
            try container.encode("workspace", forKey: .type)
            try container.encode(definition, forKey: .workspace)
            try container.encodeIfPresent(restart, forKey: .restart)
        case .actionReference(let identifier):
            try container.encode(identifier, forKey: .action)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct CmuxResolvedConfigAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var keywords: [String]
    var palette: Bool
    var shortcut: StoredShortcut?
    var icon: CmuxButtonIcon?
    var tooltip: String?
    var action: CmuxSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: CmuxConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?
    var newWorkspaceMenu: Bool?

    var terminalCommand: String? {
        action.terminalCommand
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Minimum immutable model target required to list and execute this
    /// configured action through the command palette.
    var paletteTargetRequirement: CmuxConfigPaletteTargetRequirement {
        switch action {
        case .command, .agent:
            return (terminalCommandTarget ?? .newTabInCurrentPane) == .currentTerminal
                ? .terminalPanel
                : .panelInPane
        case .workspaceCommand, .workspace:
            return .workspace
        case .builtIn(let builtIn):
            switch builtIn {
            case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect:
                return .window
            case .newTerminal, .newBrowser, .splitRight, .splitDown:
                return .panelInPane
            }
        case .actionReference:
            return .unavailable
        }
    }

    /// Whether this action should be auto-offered in the new-workspace
    /// plus-button menu: explicit `newWorkspaceMenu` wins; inline workspace
    /// actions default to true.
    var wantsNewWorkspaceMenu: Bool {
        newWorkspaceMenu ?? (action.inlineWorkspace != nil)
    }

    /// Synthetic named command for inline `type: "workspace"` actions so
    /// execution and trust fingerprinting reuse the named-command path.
    /// Carries the action's `confirm` so explicit confirmation requests
    /// survive the wrap.
    var inlineWorkspaceSyntheticCommand: CmuxCommandDefinition? {
        guard let inline = action.inlineWorkspace else { return nil }
        return CmuxCommandDefinition(
            name: title,
            restart: inline.restart,
            workspace: inline.definition,
            confirm: confirm
        )
    }

    func applying(
        _ definition: CmuxConfigActionDefinition,
        sourcePath: String?
    ) -> CmuxResolvedConfigAction? {
        var next = self
        next.title = definition.title ?? next.title
        next.subtitle = definition.subtitle ?? next.subtitle
        if let keywords = definition.keywords {
            next.keywords = keywords
        }
        next.palette = definition.palette ?? next.palette
        next.shortcut = definition.shortcut ?? next.shortcut
        if let icon = definition.icon {
            next.icon = icon
            next.iconSourcePath = sourcePath
        }
        next.tooltip = definition.tooltip ?? next.tooltip
        next.confirm = definition.confirm ?? next.confirm
        next.terminalCommandTarget = definition.terminalCommandTarget ?? next.terminalCommandTarget
        next.newWorkspaceMenu = definition.newWorkspaceMenu ?? next.newWorkspaceMenu
        next.actionSourcePath = sourcePath ?? next.actionSourcePath
        if let action = definition.action {
            next.action = action
        }
        return next
    }

    static func fromDefinition(
        id: String,
        definition: CmuxConfigActionDefinition,
        sourcePath: String?
    ) -> CmuxResolvedConfigAction? {
        guard let action = definition.action else { return nil }
        let title = definition.title
            ?? definition.tooltip
            ?? Self.defaultTitle(for: id, action: action)
        return CmuxResolvedConfigAction(
            id: id,
            title: title,
            subtitle: definition.subtitle,
            keywords: definition.keywords ?? [],
            palette: definition.palette ?? true,
            shortcut: definition.shortcut,
            icon: definition.icon ?? action.defaultButtonIcon,
            tooltip: definition.tooltip,
            action: action,
            confirm: definition.confirm,
            terminalCommandTarget: definition.terminalCommandTarget,
            actionSourcePath: sourcePath,
            iconSourcePath: definition.icon == nil ? nil : sourcePath,
            newWorkspaceMenu: definition.newWorkspaceMenu
        )
    }

    static func builtIn(_ builtIn: CmuxSurfaceTabBarBuiltInAction) -> CmuxResolvedConfigAction {
        let title: String
        let keywords: [String]
        switch builtIn {
        case .newWorkspace:
            title = String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            keywords = ["create", "new", "workspace"]
        case .newAgentChat:
            title = String(localized: "command.newAgentChat.title", defaultValue: "New agent chat")
            keywords = ["create", "new", "agent", "chat", "browser", "codex", "claude"]
        case .cloudVM:
            title = String(localized: "command.cloudVM.title", defaultValue: "Open Base")
            keywords = ["base", "cloud", "vm", "virtual", "machine", "remote"]
        case .mobileConnect:
            title = String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")
            keywords = ["iphone", "ipad", "mobile", "phone", "pair", "connect"]
        case .newTerminal:
            title = String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab")
            keywords = ["new", "terminal", "tab", "surface"]
        case .newBrowser:
            title = String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab")
            keywords = ["new", "browser", "tab", "surface"]
        case .splitRight:
            title = String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")
            keywords = ["terminal", "split", "right"]
        case .splitDown:
            title = String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")
            keywords = ["terminal", "split", "down"]
        }

        return CmuxResolvedConfigAction(
            id: builtIn.configID,
            title: title,
            subtitle: String(localized: "command.cmuxConfig.builtInSubtitle", defaultValue: "cmux"),
            keywords: keywords,
            palette: true,
            shortcut: nil,
            icon: .symbol(builtIn.defaultIcon),
            tooltip: nil,
            action: .builtIn(builtIn),
            confirm: nil,
            terminalCommandTarget: nil,
            actionSourcePath: nil,
            iconSourcePath: nil
        )
    }

    private static func defaultTitle(for id: String, action: CmuxSurfaceTabBarButtonAction) -> String {
        switch action {
        case .agent(let agent, _):
            switch agent {
            case .codex:
                return String(localized: "command.cmuxConfig.defaultCodexTitle", defaultValue: "Codex")
            case .claudeCode:
                return String(localized: "command.cmuxConfig.defaultClaudeCodeTitle", defaultValue: "Claude Code")
            case .opencode:
                return String(localized: "command.cmuxConfig.defaultOpenCodeTitle", defaultValue: "OpenCode")
            case .custom(let name):
                return name
            }
        case .command:
            return id
        case .workspaceCommand(let commandName):
            return commandName
        case .workspace(let definition, _):
            return definition.name ?? id
        case .builtIn(let builtIn):
            return builtIn.configID
        case .actionReference(let identifier):
            return identifier
        }
    }
}

struct CmuxCommandDefinition: Codable, Sendable, Identifiable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: CmuxRestartBehavior?
    var workspace: CmuxWorkspaceDefinition?
    var command: String?
    var confirm: Bool?

    var id: String {
        "cmux.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: CmuxRestartBehavior? = nil,
        workspace: CmuxWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        restart = try container.decodeIfPresent(CmuxRestartBehavior.self, forKey: .restart)
        workspace = try container.decodeIfPresent(CmuxWorkspaceDefinition.self, forKey: .workspace)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command name must not be blank"
                )
            )
        }
        if let cmd = command,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
                )
            )
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
                )
            )
        }
    }
}

indirect enum CmuxLayoutNode: Codable, Sendable, Hashable {
    case pane(CmuxPaneDefinition)
    case split(CmuxSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(CmuxPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try CmuxSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

struct CmuxSplitDefinition: Codable, Sendable, Hashable {
    var direction: CmuxSplitDirection
    var split: Double?
    var children: [CmuxLayoutNode]

    init(direction: CmuxSplitDirection, split: Double? = nil, children: [CmuxLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(CmuxSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([CmuxLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum CmuxSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct CmuxPaneDefinition: Codable, Sendable, Hashable {
    var surfaces: [CmuxSurfaceDefinition]

    init(surfaces: [CmuxSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try container.decode([CmuxSurfaceDefinition].self, forKey: .surfaces)
        if surfaces.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pane node must contain at least one surface"
                )
            )
        }
    }
}

struct CmuxSurfaceDefinition: Codable, Sendable, Hashable {
    var type: CmuxSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum CmuxSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
    case project
}

struct CmuxResolvedCommand: Sendable {
    let command: CmuxCommandDefinition
    let sourcePath: String?
}

struct CmuxConfigIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case newWorkspaceActionNotFound
        case newWorkspaceCommandNotFound
        case newWorkspaceCommandRequiresWorkspace
        case paletteActionIDCollision
        case schemaError
    }

    let kind: Kind
    let settingName: String
    let commandName: String?
    let sourcePath: String?
    let message: String?

    init(
        kind: Kind,
        settingName: String,
        commandName: String? = nil,
        sourcePath: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.settingName = settingName
        self.commandName = commandName
        self.sourcePath = sourcePath
        self.message = message
    }

    var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    var logMessage: String {
        switch kind {
        case .newWorkspaceActionNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded action"
        case .newWorkspaceCommandNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded command"
        case .newWorkspaceCommandRequiresWorkspace:
            return "\(settingName) '\(commandName ?? "")' must reference a workspace command"
        case .paletteActionIDCollision:
            return "\(settingName) '\(commandName ?? "")' conflicts with a cmux command palette action"
        case .schemaError:
            return "\(settingName) has a schema error: \(message ?? "unknown error")"
        }
    }
}

@MainActor
final class CmuxConfigStore: ObservableObject {
    private static let defaultNewWorkspaceContextMenu: [CmuxConfigContextMenuItem] = [
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)),
    ]

    @Published private(set) var loadedCommands: [CmuxCommandDefinition] = []
    @Published private(set) var loadedActions: [CmuxResolvedConfigAction] = []
    @Published private(set) var newWorkspaceCommandName: String?
    @Published private(set) var newWorkspaceActionID: String?
    @Published private(set) var newWorkspaceContextMenuItems: [CmuxResolvedConfigContextMenuItem] = []
    @Published private(set) var newWorkspaceContextMenuIsConfigured = false
    @Published private(set) var newWorkspaceMenuSectionOrder: CmuxNewWorkspaceMenuSectionOrder = .default
    @Published private(set) var agentChat: CmuxAgentChatConfiguration = .default
    /// Resolved per-cwd workspace group customization, keyed by the JSON cwd key.
    /// Use `resolveWorkspaceGroupConfig(forCwd:)` to find the best match for an
    /// anchor workspace's cwd. Empty when no `workspaceGroups.byCwd` block is
    /// configured.
    @Published private(set) var workspaceGroupConfigs: [CmuxResolvedWorkspaceGroupConfig] = []
    @Published private(set) var surfaceTabBarButtons: [CmuxSurfaceTabBarButton] = CmuxSurfaceTabBarButton.defaults
    @Published private(set) var notificationHooks: [CmuxResolvedNotificationHook] = []
    @Published private(set) var configurationIssues: [CmuxConfigIssue] = []
    @Published private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    private(set) var commandSourcePaths: [String: String] = [:]
    private(set) var actionLookup: [String: CmuxResolvedConfigAction] = [:]
    private(set) var surfaceTabBarButtonSourcePath: String?
    private(set) var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    private(set) var newWorkspaceActionSourcePath: String?

    private(set) var localConfigPath: String?
    private weak var tabManager: TabManager?
    let globalConfigPath: String
    private let fileWatchingEnabled: Bool
    private let actionCatalogRawReader: any CmuxConfigActionCatalogRawReading
    private let actionCatalogReadCoordinator: CmuxConfigActionCatalogReadCoordinator

    nonisolated static func defaultGlobalConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    private struct ActionEntry {
        let definition: CmuxConfigActionDefinition
        let sourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtonEntry {
        let button: CmuxSurfaceTabBarButton
        let terminalCommandSourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtons {
        let buttons: [CmuxSurfaceTabBarButton]
        let terminalCommandSourcePaths: [String: String]
    }

    private struct ResolvedContextMenuItems {
        let items: [CmuxResolvedConfigContextMenuItem]
        let issues: [CmuxConfigIssue]
    }

    private struct NewWorkspaceCommandResolution {
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    private struct NewWorkspaceActionResolution {
        let action: CmuxResolvedConfigAction?
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    private struct ParsedConfigCacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let workspaceColorPaletteFingerprint: String
        let contentDigest: String
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
    }

    private struct ParsedConfigResult {
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
        let contentDigest: String
    }

    private var surfaceTabBarWorkspaceCommands: [String: CmuxResolvedCommand] = [:]
    private var resolvedNewWorkspaceCommandCache: CmuxResolvedCommand?
    private var resolvedNewWorkspaceActionCache: CmuxResolvedConfigAction?
    private var loadedActionCatalogSnapshot: CmuxConfigActionCatalogSnapshot?
    private var actionCatalogSnapshotsByKey: [String: CmuxConfigActionCatalogSnapshot] = [:]
    /// Shared-input baseline established only by synchronous `loadAll()`.
    /// A standalone `<global>` background refresh must not advance it while
    /// per-directory snapshots still embed the previous global bytes.
    private var lastLoadAllGlobalSourceFingerprint: String?
    private var actionCatalogRefreshTasks: [String: Task<CmuxConfigActionCatalogSnapshot?, Never>] = [:]
    private var actionCatalogRefreshTokens: [String: UUID] = [:]
    private var actionCatalogRefreshSequence: UInt64 = 0
    private var actionCatalogFreshWaiters:
        [String: [UUID: CmuxConfigActionCatalogFreshWaiter]] = [:]
    private var actionCatalogDirectoryIndex = CmuxConfigActionCatalogDirectoryIndex(
        globalKey: "<global>"
    )
    private var actionCatalogTrackedWorkspaceIdentities: [UUID: ObjectIdentifier] = [:]
    private var actionCatalogStructuralRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var trackingCancellables = Set<AnyCancellable>()
    private var actionCatalogTrackingTasks: [UUID: Task<Void, Never>] = [:]
    // The local config still uses a bespoke DispatchSource watcher because it
    // performs search-directory *path re-resolution* (not just reload-on-change).
    // The global config and hook files use CmuxFileWatch.FileWatcher.
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    private var localFileDescriptor: Int32 = -1
    private var localConfigSearchDirectory: String?
    private var hookWatchers: [String: FileWatcher] = [:]
    private var hookWatchTasks: [String: Task<Void, Never>] = [:]
    private var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    private var localFallbackDirectoryDescriptor: Int32 = -1
    private var globalWatcher: FileWatcher?
    private var globalWatchTask: Task<Void, Never>?
    private let watchQueue = DispatchQueue(label: "com.cmux.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    private static func searchDirectoryForLocalConfigPath(_ path: String) -> String {
        let configDirectory = (path as NSString).deletingLastPathComponent
        if (configDirectory as NSString).lastPathComponent == ".cmux" {
            return (configDirectory as NSString).deletingLastPathComponent
        }
        return configDirectory
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    init(
        globalConfigPath: String = CmuxConfigStore.defaultGlobalConfigPath(),
        localConfigPath: String? = nil,
        startFileWatchers: Bool = false,
        actionCatalogRawReader: any CmuxConfigActionCatalogRawReading =
            CmuxConfigActionCatalogProcessReader.shared,
        actionCatalogReadCoordinator: CmuxConfigActionCatalogReadCoordinator = .shared
    ) {
        self.globalConfigPath = globalConfigPath
        self.localConfigPath = localConfigPath
        self.fileWatchingEnabled = startFileWatchers
        self.actionCatalogRawReader = actionCatalogRawReader
        self.actionCatalogReadCoordinator = actionCatalogReadCoordinator
        self.localConfigSearchDirectory = localConfigPath.map(Self.searchDirectoryForLocalConfigPath(_:))
        NotificationCenter.default.publisher(for: CmuxActionTrust.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadAll()
            }
            .store(in: &lifetimeCancellables)
        if startFileWatchers {
            if localConfigPath != nil {
                startLocalFileWatcher()
            }
            startGlobalWatching()
        }
    }

    deinit {
        actionCatalogTrackingTasks.values.forEach { $0.cancel() }
        actionCatalogStructuralRefreshTasks.values.forEach { $0.cancel() }
        actionCatalogRefreshTasks.values.forEach { $0.cancel() }
        for waiters in actionCatalogFreshWaiters.values {
            for waiter in waiters.values {
                waiter.deadlineTimer?.invalidate()
                waiter.continuation.resume(returning: nil)
            }
        }
        localFileWatchSource?.cancel()
        localFallbackDirectoryWatchSource?.cancel()
        hookWatchTasks.values.forEach { $0.cancel() }
        globalWatchTask?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        trackingCancellables.removeAll()
        self.tabManager = tabManager

        tabManager.selectedTabIdPublisher
            .map { [weak tabManager] tabId -> AnyPublisher<String?, Never> in
                guard let tabId,
                      let workspace = tabManager?.tabs.first(where: { $0.id == tabId }) else {
                    return Just(nil).eraseToAnyPublisher()
                }
                return workspace.$surfaceTabBarDirectory.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &trackingCancellables)

        tabManager.tabsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                self?.applySurfaceTabBarButtonsToCurrentManager()
                self?.reconcileActionCatalogWorkspaceTracking(in: tabs)
            }
            .store(in: &trackingCancellables)
    }

    func notificationHooks(startingFrom directory: String?) -> [CmuxResolvedNotificationHook] {
        let globalConfig = parseConfig(at: globalConfigPath).config
        let localConfigs: [(path: String, config: CmuxConfigFile)]
        if let directory, !directory.isEmpty {
            localConfigs = findCmuxConfigHierarchy(startingFrom: directory).compactMap { path in
                parseConfig(at: path).config.map { (path: path, config: $0) }
            }
        } else {
            localConfigs = []
        }
        return resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localConfigs
        )
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            localConfigSearchDirectory = directory
            newPath = resolvedLocalConfigPath(startingFrom: directory)
        } else {
            localConfigSearchDirectory = nil
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if fileWatchingEnabled, newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        findCmuxConfig(startingFrom: directory)
            ?? defaultLocalConfigPath(startingFrom: directory)
    }

    private func defaultLocalConfigPath(startingFrom directory: String) -> String {
        (((directory as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("cmux.json"))
    }

    private func findCmuxConfig(startingFrom directory: String) -> String? {
        var current = directory
        let fs = FileManager.default
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            for candidate in candidates where fs.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private func findCmuxConfigHierarchy(startingFrom directory: String) -> [String] {
        var current = directory
        let fs = FileManager.default
        var paths: [String] = []
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            if let candidate = candidates.first(where: { fs.fileExists(atPath: $0) }) {
                paths.append(candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return paths.reversed()
    }

    /// Lexical cache identity for one config lookup directory. Standardizing
    /// the path does not touch the filesystem, so palette reads remain safe on
    /// network-backed or disconnected working directories.
    nonisolated static func actionCatalogCacheKey(startingFrom directory: String?) -> String {
        normalizedActionCatalogDirectory(startingFrom: directory) ?? "<global>"
    }

    private nonisolated static func normalizedActionCatalogDirectory(
        startingFrom directory: String?
    ) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(String(trimmed.dropFirst(2)))
        } else {
            expanded = trimmed
        }
        guard (expanded as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    /// Runs killable filesystem discovery/read in the bundled CLI helper, then
    /// decodes the bounded bytes without touching main-actor state. Callers
    /// resolve the returned source into a catalog on the main actor.
    nonisolated static func loadActionCatalogSource(
        startingFrom directory: String?,
        globalConfigPath: String,
        workspaceColorPalette: [String: String],
        rawReader: any CmuxConfigActionCatalogRawReading
    ) async -> CmuxConfigActionCatalogSource? {
        let normalizedDirectory = normalizedActionCatalogDirectory(startingFrom: directory)
        guard let rawSource = await rawReader.read(
            request: CmuxConfigActionCatalogRawReadRequest(
                directory: normalizedDirectory,
                globalConfigPath: globalConfigPath,
                maximumConfigBytes: CmuxConfigActionCatalogProcessReader
                    .defaultMaximumConfigBytes
            )
        ) else {
            return nil
        }
        let local = rawSource.localPath.flatMap { localPath in
            rawSource.local.map {
                backgroundParseConfig(
                    $0,
                    at: localPath,
                    workspaceColorPalette: workspaceColorPalette
                )
            }
        }
        let global = backgroundParseConfig(
            rawSource.global,
            at: globalConfigPath,
            workspaceColorPalette: workspaceColorPalette
        )
        return CmuxConfigActionCatalogSource(
            localPath: rawSource.localPath,
            local: local,
            global: global,
            fingerprint: actionCatalogSourceFingerprint(
                localPath: rawSource.localPath,
                localContentDigest: local?.contentDigest,
                globalConfigPath: globalConfigPath,
                globalContentDigest: global.contentDigest,
                workspaceColorPaletteFingerprint: WorkspaceTabColorSettings
                    .paletteCacheFingerprint(workspaceColorPalette)
            )
        )
    }

    private nonisolated static func backgroundParseConfig(
        _ rawFile: CmuxConfigActionCatalogRawFile,
        at path: String,
        workspaceColorPalette: [String: String]
    ) -> CmuxConfigActionCatalogSource.ParsedConfig {
        switch rawFile.status {
        case .missing:
            return .init(config: nil, issue: nil, contentDigest: "<missing>")
        case .unreadable:
            return .init(
                config: nil,
                issue: backgroundSchemaIssue(path: path, message: "cmux.json is empty"),
                contentDigest: "<unreadable>"
            )
        case .tooLarge:
            return .init(
                config: nil,
                issue: backgroundSchemaIssue(
                    path: path,
                    message: actionCatalogTooLargeMessage(
                        maximumBytes: CmuxConfigActionCatalogProcessReader.defaultMaximumConfigBytes
                    )
                ),
                contentDigest: "<too-large:\(CmuxConfigActionCatalogProcessReader.defaultMaximumConfigBytes)>"
            )
        case .data:
            break
        }
        let data = rawFile.data
        let contentDigest = actionCatalogContentDigest(data)
        guard !data.isEmpty else {
            return .init(
                config: nil,
                issue: backgroundSchemaIssue(path: path, message: "cmux.json is empty"),
                contentDigest: contentDigest
            )
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            return .init(
                config: nil,
                issue: backgroundSchemaIssue(
                    path: path,
                    message: "JSONC preprocessing failed: \(backgroundSchemaErrorMessage(error))"
                ),
                contentDigest: contentDigest
            )
        }
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.cmuxWorkspaceColorDefaults] = workspaceColorPalette
            return .init(
                config: try decoder.decode(CmuxConfigFile.self, from: sanitized),
                issue: nil,
                contentDigest: contentDigest
            )
        } catch {
            return .init(
                config: nil,
                issue: backgroundSchemaIssue(
                    path: path,
                    message: backgroundSchemaErrorMessage(error)
                ),
                contentDigest: contentDigest
            )
        }
    }

    private nonisolated static func actionCatalogContentDigest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    nonisolated static func actionCatalogTooLargeMessage(
        maximumBytes: Int,
        locale: Locale = .current
    ) -> String {
        let format = String(
            localized: "config.actionCatalog.error.tooLarge",
            defaultValue: "cmux.json exceeds the %lld-byte action catalog limit",
            table: nil,
            bundle: .main,
            locale: locale,
            comment: "Config error when cmux.json exceeds the action catalog byte limit"
        )
        return String(format: format, Int64(maximumBytes))
    }

    private nonisolated static func actionCatalogSourceFingerprint(
        localPath: String?,
        localContentDigest: String?,
        globalConfigPath: String,
        globalContentDigest: String,
        workspaceColorPaletteFingerprint: String
    ) -> String {
        let identity = [
            localPath ?? "<none>",
            localContentDigest ?? "<none>",
            globalConfigPath,
            globalContentDigest,
            workspaceColorPaletteFingerprint,
        ].joined(separator: "\u{0}")
        return actionCatalogContentDigest(Data(identity.utf8))
    }

    private nonisolated static func backgroundSchemaIssue(
        path: String,
        message: String
    ) -> CmuxConfigIssue {
        CmuxConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    private nonisolated static func backgroundSchemaErrorMessage(_ error: Error) -> String {
        let context: DecodingError.Context?
        let extraKey: CodingKey?
        switch error {
        case DecodingError.typeMismatch(_, let value),
             DecodingError.valueNotFound(_, let value),
             DecodingError.dataCorrupted(let value):
            context = value
            extraKey = nil
        case DecodingError.keyNotFound(let key, let value):
            context = value
            extraKey = key
        default:
            return backgroundSanitizedConfigText(error.localizedDescription)
        }
        guard let context else { return String(describing: error) }
        let codingPath = context.codingPath + (extraKey.map { [$0] } ?? [])
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        let detail = backgroundSanitizedConfigText(context.debugDescription)
        if path.isEmpty { return detail }
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    private nonisolated static func backgroundSanitizedConfigText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
        ]
        return String(text.unicodeScalars.filter { !dangerous.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func actionCatalog(from source: CmuxConfigActionCatalogSource) -> CmuxConfigActionCatalog {
        return resolveActionCatalog(
            localConfig: source.local?.config,
            localIssue: source.local?.issue,
            localPath: source.localPath,
            globalConfig: source.global.config,
            globalIssue: source.global.issue
        )
    }

    /// Pure in-memory lookup used by command-palette registry construction.
    /// A hit is returned immediately and revalidated in the background. A miss
    /// schedules detached discovery and fails closed at the caller.
    func cachedActionCatalogSnapshot(
        startingFrom directory: String?,
        revalidate: Bool = true
    ) -> CmuxConfigActionCatalogSnapshot? {
        let key = Self.actionCatalogCacheKey(startingFrom: directory)
        if let cached = actionCatalogSnapshotsByKey[key] {
            if revalidate {
                scheduleActionCatalogRefresh(
                    startingFrom: directory,
                    policy: .revalidate
                )
            }
            return cached
        }
        if revalidate {
            scheduleActionCatalogRefresh(
                startingFrom: directory,
                policy: .ifMissing
            )
        }
        return nil
    }

    func cachedActionCatalog(
        startingFrom directory: String?,
        revalidate: Bool = true
    ) -> CmuxConfigActionCatalog? {
        cachedActionCatalogSnapshot(
            startingFrom: directory,
            revalidate: revalidate
        )?.catalog
    }

    /// Waits for one shared bounded off-main config read and returns the snapshot it
    /// published. Socket-worker palette calls use this freshness boundary
    /// before they hop back to the main actor to list or execute handlers.
    func freshActionCatalogSnapshot(
        startingFrom directory: String?,
        deadline: Date? = nil
    ) async -> CmuxConfigActionCatalogSnapshot? {
        let key = Self.actionCatalogCacheKey(startingFrom: directory)
        let minimumRefreshSequence = actionCatalogRefreshSequence &+ 1
        guard deadline.map({ Date() < $0 }) ?? true else { return nil }
        let waiterID = UUID()

        // One continuation per request avoids periodic MainActor wakeups. A
        // task that began before this call cannot satisfy the waiter's minimum
        // sequence. Its completion starts one coalesced follow-up generation.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let deadlineTimer = deadline.map { deadline in
                    let timer = Timer(fire: deadline, interval: 0, repeats: false) {
                        [weak self] _ in
                        Task { @MainActor [weak self] in
                        self?.finishActionCatalogFreshWaiter(
                            key: key,
                            waiterID: waiterID,
                            snapshot: nil
                        )
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    return timer
                }
                actionCatalogFreshWaiters[key, default: [:]][waiterID] =
                    CmuxConfigActionCatalogFreshWaiter(
                        minimumRefreshSequence: minimumRefreshSequence,
                        directory: directory,
                        continuation: continuation,
                        deadlineTimer: deadlineTimer
                    )
                scheduleActionCatalogRefreshForFreshWaitersIfNeeded(key: key)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishActionCatalogFreshWaiter(
                    key: key,
                    waiterID: waiterID,
                    snapshot: nil
                )
            }
        }
    }

    @discardableResult
    func refreshActionCatalog(startingFrom directory: String?) async -> CmuxConfigActionCatalog {
        if let snapshot = await refreshedActionCatalogSnapshot(
            startingFrom: directory,
            policy: .replace
        ) {
            return snapshot.catalog
        }
        return cachedActionCatalog(startingFrom: directory, revalidate: false)
            ?? currentActionCatalog()
    }

    func currentActionCatalog() -> CmuxConfigActionCatalog {
        if let loadedActionCatalogSnapshot { return loadedActionCatalogSnapshot.catalog }
        return unconfiguredActionCatalog()
    }

    /// A catalog containing only cmux-owned built-ins. Use this when the
    /// target directory's config has not been resolved yet so actions from a
    /// different directory cannot leak into the target's palette.
    func unconfiguredActionCatalog() -> CmuxConfigActionCatalog {
        return resolveActionCatalog(
            localConfig: nil,
            localIssue: nil,
            localPath: nil,
            globalConfig: nil,
            globalIssue: nil
        )
    }

    private func reconcileActionCatalogWorkspaceTracking(in tabs: [Workspace]) {
        let liveWorkspaces = Dictionary(
            tabs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (workspaceID, identity) in Array(actionCatalogTrackedWorkspaceIdentities) {
            guard let workspace = liveWorkspaces[workspaceID],
                  ObjectIdentifier(workspace) == identity else {
                stopTrackingActionCatalogDirectories(workspaceID: workspaceID)
                continue
            }
        }

        for workspace in tabs {
            let identity = ObjectIdentifier(workspace)
            guard actionCatalogTrackedWorkspaceIdentities[workspace.id] != identity else {
                continue
            }
            reconcileTrackedActionCatalogDirectories(for: workspace)
            actionCatalogTrackedWorkspaceIdentities[workspace.id] = identity
            let events = workspace.configTrackingEvents
            actionCatalogTrackingTasks[workspace.id] = Task {
                @MainActor [weak self, weak workspace] in
                for await event in events {
                    guard !Task.isCancelled, let self, let workspace else { return }
                    self.handleActionCatalogTrackingEvent(event, workspace: workspace)
                }
            }
        }
        prewarmTrackedActionCatalogDirectories()
    }

    private func stopTrackingActionCatalogDirectories(workspaceID: UUID) {
        actionCatalogTrackingTasks.removeValue(forKey: workspaceID)?.cancel()
        actionCatalogStructuralRefreshTasks.removeValue(forKey: workspaceID)?.cancel()
        actionCatalogTrackedWorkspaceIdentities.removeValue(forKey: workspaceID)
        applyActionCatalogDirectoryIndexMutation(
            actionCatalogDirectoryIndex.removeWorkspace(workspaceID: workspaceID)
        )
    }

    private func handleActionCatalogTrackingEvent(
        _ event: WorkspaceConfigTrackingEvent,
        workspace: Workspace
    ) {
        guard actionCatalogTrackedWorkspaceIdentities[workspace.id] == ObjectIdentifier(workspace) else {
            return
        }
        switch event {
        case .panelDirectoryChanged(let panelID):
            let source = CmuxConfigActionCatalogDirectorySource.panel(
                workspaceID: workspace.id,
                panelID: panelID
            )
            let mutation: CmuxConfigActionCatalogDirectoryIndexMutation
            if workspace.panels[panelID] != nil {
                mutation = actionCatalogDirectoryIndex.replaceContribution(
                    source: source,
                    key: trackedActionCatalogKey(
                        for: workspace.configurationTrackingPanelContributionDirectory(
                            panelID: panelID
                        )
                    )
                )
            } else {
                mutation = actionCatalogDirectoryIndex.removeContribution(source: source)
            }
            applyActionCatalogDirectoryIndexMutation(mutation)
            if tabManager?.selectedTabId == workspace.id,
               workspace.focusedPanelId == panelID {
                prewarmTrackedActionCatalogDirectories(for: workspace)
            }
        case .workspaceDirectoryChanged:
            applyActionCatalogDirectoryIndexMutation(
                actionCatalogDirectoryIndex.replaceContribution(
                    source: .workspace(workspace.id),
                    key: trackedActionCatalogKey(
                        for: workspace.configurationTrackingDirectory(panelID: nil)
                    )
                )
            )
            if tabManager?.selectedTabId == workspace.id {
                prewarmTrackedActionCatalogDirectories(for: workspace)
            }
        case .structuralChanged:
            scheduleStructuralActionCatalogDirectoryRefresh(for: workspace)
        }
    }

    /// `panelsWillChange(to:)` emits before PaneTreeModel stores its new value.
    /// Deferring one main-actor turn guarantees structural reconciliation reads
    /// the post-mutation panel registry while coalescing synchronous churn.
    private func scheduleStructuralActionCatalogDirectoryRefresh(for workspace: Workspace) {
        let workspaceID = workspace.id
        actionCatalogStructuralRefreshTasks.removeValue(forKey: workspaceID)?.cancel()
        actionCatalogStructuralRefreshTasks[workspaceID] = Task {
            @MainActor [weak self, weak workspace] in
            await Task.yield()
            guard !Task.isCancelled, let self, let workspace,
                  self.actionCatalogTrackedWorkspaceIdentities[workspaceID]
                    == ObjectIdentifier(workspace) else {
                return
            }
            self.reconcileTrackedActionCatalogDirectories(for: workspace)
        }
    }

    private func reconcileTrackedActionCatalogDirectories(for workspace: Workspace) {
        var panelKeys: [UUID: String] = [:]
        for panelID in workspace.panels.keys {
            if let key = trackedActionCatalogKey(
                for: workspace.configurationTrackingPanelContributionDirectory(
                    panelID: panelID
                )
            ) {
                panelKeys[panelID] = key
            }
        }
        applyActionCatalogDirectoryIndexMutation(
            actionCatalogDirectoryIndex.replaceWorkspace(
                workspaceID: workspace.id,
                workspaceKey: trackedActionCatalogKey(
                    for: workspace.configurationTrackingDirectory(panelID: nil)
                ),
                panelKeys: panelKeys
            )
        )
        if tabManager?.selectedTabId == workspace.id {
            prewarmTrackedActionCatalogDirectories(for: workspace)
        }
    }

    private func trackedActionCatalogKey(for directory: String?) -> String? {
        guard let directory else { return nil }
        return Self.actionCatalogCacheKey(startingFrom: directory)
    }

    private func applyActionCatalogDirectoryIndexMutation(
        _ mutation: CmuxConfigActionCatalogDirectoryIndexMutation
    ) {
        for key in mutation.inactiveKeys
            where actionCatalogDirectoryIndex.referenceCount(for: key) == 0 {
            actionCatalogRefreshTasks.removeValue(forKey: key)?.cancel()
            actionCatalogRefreshTokens.removeValue(forKey: key)
            actionCatalogSnapshotsByKey.removeValue(forKey: key)
            finishAllActionCatalogFreshWaiters(key: key)
        }
    }

    private func prewarmTrackedActionCatalogDirectories() {
        if let selectedWorkspace = tabManager?.selectedWorkspace {
            prewarmTrackedActionCatalogDirectories(for: selectedWorkspace)
        } else {
            scheduleActionCatalogRefresh(startingFrom: nil, policy: .ifMissing)
        }
    }

    private func prewarmTrackedActionCatalogDirectories(for selectedWorkspace: Workspace) {
        scheduleActionCatalogRefresh(startingFrom: nil, policy: .ifMissing)
        scheduleActionCatalogRefresh(
            startingFrom: selectedWorkspace.configurationTrackingDirectory(panelID: nil),
            policy: .ifMissing
        )
        if let focusedPanelID = selectedWorkspace.focusedPanelId {
            scheduleActionCatalogRefresh(
                startingFrom: selectedWorkspace.configurationTrackingDirectory(
                    panelID: focusedPanelID
                ),
                policy: .ifMissing
            )
        }
    }

    private func scheduleActionCatalogRefreshForFreshWaitersIfNeeded(key: String) {
        guard actionCatalogRefreshTasks[key] == nil,
              let waiter = actionCatalogFreshWaiters[key]?.values.first else {
            return
        }
        _ = scheduleActionCatalogRefresh(
            startingFrom: waiter.directory,
            policy: .replace
        )
    }

    private func finishActionCatalogFreshWaiter(
        key: String,
        waiterID: UUID,
        snapshot: CmuxConfigActionCatalogSnapshot?
    ) {
        guard var waiters = actionCatalogFreshWaiters[key],
              let waiter = waiters.removeValue(forKey: waiterID) else {
            return
        }
        if waiters.isEmpty {
            actionCatalogFreshWaiters.removeValue(forKey: key)
        } else {
            actionCatalogFreshWaiters[key] = waiters
        }
        waiter.deadlineTimer?.invalidate()
        waiter.continuation.resume(returning: snapshot)
    }

    private func finishAllActionCatalogFreshWaiters(key: String) {
        guard let waiters = actionCatalogFreshWaiters.removeValue(forKey: key) else {
            return
        }
        for waiter in waiters.values {
            waiter.deadlineTimer?.invalidate()
            waiter.continuation.resume(returning: nil)
        }
    }

    private func resolveActionCatalogFreshWaiters(
        key: String,
        completedRefreshSequence: UInt64,
        snapshot: CmuxConfigActionCatalogSnapshot
    ) {
        guard let waiters = actionCatalogFreshWaiters[key] else { return }
        let completedWaiterIDs = waiters.compactMap { waiterID, waiter in
            waiter.minimumRefreshSequence <= completedRefreshSequence ? waiterID : nil
        }
        for waiterID in completedWaiterIDs {
            finishActionCatalogFreshWaiter(
                key: key,
                waiterID: waiterID,
                snapshot: snapshot
            )
        }
    }

    private func refreshedActionCatalogSnapshot(
        startingFrom directory: String?,
        policy: CmuxConfigActionCatalogRefreshPolicy
    ) async -> CmuxConfigActionCatalogSnapshot? {
        var nextPolicy = policy
        // A forced refresh can be superseded by another forced refresh while
        // its detached read is suspended. Join the replacement instead of
        // publishing or returning the superseded source.
        for _ in 0..<3 {
            if let task = scheduleActionCatalogRefresh(
                startingFrom: directory,
                policy: nextPolicy
            ), let snapshot = await task.value {
                return snapshot
            }
            nextPolicy = .revalidate
        }
        return nil
    }

    @discardableResult
    private func scheduleActionCatalogRefresh(
        startingFrom directory: String?,
        policy: CmuxConfigActionCatalogRefreshPolicy
    ) -> Task<CmuxConfigActionCatalogSnapshot?, Never>? {
        let key = Self.actionCatalogCacheKey(startingFrom: directory)
        switch policy {
        case .ifMissing:
            if actionCatalogSnapshotsByKey[key] != nil {
                return nil
            }
            if let task = actionCatalogRefreshTasks[key] { return task }
        case .revalidate:
            if let task = actionCatalogRefreshTasks[key] { return task }
        case .replace:
            actionCatalogRefreshTasks.removeValue(forKey: key)?.cancel()
        }
        let refreshToken = UUID()
        actionCatalogRefreshSequence &+= 1
        let refreshSequence = actionCatalogRefreshSequence
        actionCatalogRefreshTokens[key] = refreshToken
        let globalConfigPath = globalConfigPath
        let readCoordinationKey = globalConfigPath + "\u{0}" + key
        let readLane: CmuxConfigActionCatalogReadCoordinator.Lane = key == Self
            .actionCatalogCacheKey(startingFrom: nil) ? .global : .general
        let workspaceColorPalette = WorkspaceTabColorSettings.resolvedPaletteMap()
        let rawReader = actionCatalogRawReader
        let readCoordinator = actionCatalogReadCoordinator
        let task: Task<CmuxConfigActionCatalogSnapshot?, Never> = Task { @MainActor [weak self] in
            let source = await readCoordinator.run(
                key: readCoordinationKey,
                lane: readLane,
                requestID: refreshToken
            ) {
                await Self.loadActionCatalogSource(
                    startingFrom: directory,
                    globalConfigPath: globalConfigPath,
                    workspaceColorPalette: workspaceColorPalette,
                    rawReader: rawReader
                )
            }
            guard let self else { return nil }
            guard let source else {
                if self.actionCatalogRefreshTokens[key] == refreshToken {
                    self.actionCatalogRefreshTasks.removeValue(forKey: key)
                    self.actionCatalogRefreshTokens.removeValue(forKey: key)
                    // The bounded scheduler rejected this distinct key. Fail
                    // closed instead of spinning retries while its queue is full.
                    self.finishAllActionCatalogFreshWaiters(key: key)
                }
                return nil
            }
            guard self.actionCatalogRefreshTokens[key] == refreshToken else {
                return nil
            }
            self.actionCatalogRefreshTasks.removeValue(forKey: key)
            self.actionCatalogRefreshTokens.removeValue(forKey: key)
            guard !Task.isCancelled else { return nil }
            let snapshot = self.storeActionCatalogSnapshot(
                self.actionCatalog(from: source),
                forKey: key,
                sourceFingerprint: source.fingerprint
            )
            self.resolveActionCatalogFreshWaiters(
                key: key,
                completedRefreshSequence: refreshSequence,
                snapshot: snapshot
            )
            self.scheduleActionCatalogRefreshForFreshWaitersIfNeeded(key: key)
            return snapshot
        }
        actionCatalogRefreshTasks[key] = task
        return task
    }

    @discardableResult
    func storeActionCatalogSnapshot(
        _ catalog: @autoclosure () -> CmuxConfigActionCatalog,
        forKey key: String,
        sourceFingerprint: String,
        notifyActiveChange: Bool = true
    ) -> CmuxConfigActionCatalogSnapshot {
        if let existing = actionCatalogSnapshotsByKey[key],
           existing.sourceFingerprint == sourceFingerprint {
            return existing
        }
        let snapshot = CmuxConfigActionCatalogSnapshot(
            id: UUID(),
            cacheKey: key,
            sourceFingerprint: sourceFingerprint,
            catalog: catalog()
        )
        actionCatalogSnapshotsByKey[key] = snapshot
        if notifyActiveChange,
           key == Self.actionCatalogCacheKey(startingFrom: localConfigSearchDirectory) {
            configRevision &+= 1
        }
        return snapshot
    }

    private func resolveActionCatalog(
        localConfig: CmuxConfigFile?,
        localIssue: CmuxConfigIssue?,
        localPath: String?,
        globalConfig: CmuxConfigFile?,
        globalIssue: CmuxConfigIssue?
    ) -> CmuxConfigActionCatalog {
        var commands: [CmuxCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]
        var configuredNewWorkspaceActionID: String?
        var configuredNewWorkspaceActionSourcePath: String?
        var configuredNewWorkspaceCommandName: String?
        var configuredNewWorkspaceCommandSourcePath: String?
        var issues = [CmuxConfigIssue]()
        if let localIssue { issues.append(localIssue) }
        if let globalIssue { issues.append(globalIssue) }

        if let localConfig {
            if let actionID = localConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = actionID
                configuredNewWorkspaceActionSourcePath = localPath
            }
            if configuredNewWorkspaceActionID == nil,
               let commandName = localConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = commandName
                configuredNewWorkspaceCommandSourcePath = localPath
            }
            for command in localConfig.commands where seenNames.insert(command.name).inserted {
                commands.append(command)
                if let localPath { sourcePaths[command.id] = localPath }
            }
        }

        if let globalConfig {
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let actionID = globalConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = actionID
                configuredNewWorkspaceActionSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let commandName = globalConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = commandName
                configuredNewWorkspaceCommandSourcePath = globalConfigPath
            }
            for command in globalConfig.commands where seenNames.insert(command.name).inserted {
                commands.append(command)
                sourcePaths[command.id] = globalConfigPath
            }
        }

        let localActions = localConfig.map {
            actionEntries(from: $0.actions, sourcePath: localPath)
        } ?? [:]
        let globalActions = globalConfig.map {
            actionEntries(from: $0.actions, sourcePath: globalConfigPath)
        } ?? [:]
        let actions = resolvedActionRegistry(
            globalActions: globalActions,
            localActions: localActions,
            commands: commands,
            commandSourcePaths: sourcePaths
        )
        let actionLookup = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        let newWorkspaceResolution = resolvedConfiguredNewWorkspaceAction(
            actionID: configuredNewWorkspaceActionID,
            actionSourcePath: configuredNewWorkspaceActionSourcePath,
            commandName: configuredNewWorkspaceCommandName,
            commandSourcePath: configuredNewWorkspaceCommandSourcePath,
            actions: actionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        if let issue = newWorkspaceResolution.issue { issues.append(issue) }

        return CmuxConfigActionCatalog(
            loadedCommands: commands,
            loadedActions: actions,
            commandSourcePaths: sourcePaths,
            configurationIssues: issues,
            resolvedNewWorkspaceAction: newWorkspaceResolution.action,
            resolvedNewWorkspaceCommand: newWorkspaceResolution.command,
            configuredNewWorkspaceActionID: configuredNewWorkspaceActionID,
            configuredNewWorkspaceActionSourcePath: configuredNewWorkspaceActionSourcePath,
            configuredNewWorkspaceCommandName: configuredNewWorkspaceCommandName,
            configuredNewWorkspaceCommandSourcePath: configuredNewWorkspaceCommandSourcePath
        )
    }

    func loadAll() {
        // A reload is an explicit freshness boundary. Size and modification
        // time alone cannot distinguish equal-length edits with preserved
        // metadata, so never carry parsed bytes across reload generations.
        parsedConfigCache.removeAll(keepingCapacity: true)
        var configuredNewWorkspaceContextMenu: [CmuxConfigContextMenuItem]?
        var configuredNewWorkspaceContextMenuSourcePath: String?
        var configuredNewWorkspaceMenuSectionOrder: CmuxNewWorkspaceMenuSectionOrder?
        var configuredSurfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
        var configuredSurfaceTabBarButtonSourcePath: String?
        let localPath = localConfigPath
        let localParseResult = localPath.map { parseConfig(at: $0) }
        let globalParseResult = parseConfig(at: globalConfigPath)
        let localConfig = localParseResult?.config
        let globalConfig = globalParseResult.config
        let actionCatalog = resolveActionCatalog(
            localConfig: localConfig,
            localIssue: localParseResult?.issue,
            localPath: localPath,
            globalConfig: globalConfig,
            globalIssue: globalParseResult.issue
        )
        let activeCatalogDirectory = localConfigSearchDirectory
        let activeCatalogKey = Self.actionCatalogCacheKey(
            startingFrom: activeCatalogDirectory
        )
        let globalCatalogKey = Self.actionCatalogCacheKey(startingFrom: nil)
        let paletteFingerprint = WorkspaceTabColorSettings.paletteCacheFingerprint()
        let globalSourceFingerprint = Self.actionCatalogSourceFingerprint(
            localPath: nil,
            localContentDigest: nil,
            globalConfigPath: globalConfigPath,
            globalContentDigest: globalParseResult.contentDigest,
            workspaceColorPaletteFingerprint: paletteFingerprint
        )
        let globalInputsChanged = lastLoadAllGlobalSourceFingerprint.map {
            $0 != globalSourceFingerprint
        } ?? true
        if globalInputsChanged {
            // Every per-directory catalog embeds these shared inputs. Invalidate
            // every publication token and cached identity when they change.
            actionCatalogRefreshTasks.values.forEach { $0.cancel() }
            actionCatalogRefreshTasks.removeAll(keepingCapacity: true)
            actionCatalogRefreshTokens.removeAll(keepingCapacity: true)
            actionCatalogSnapshotsByKey.removeAll(keepingCapacity: true)
        } else {
            // Selection and local-file reloads only revalidate the active key.
            // Keeping its snapshot until fingerprint comparison preserves an
            // exact list target when the underlying bytes did not change.
            actionCatalogRefreshTasks.removeValue(forKey: activeCatalogKey)?.cancel()
            actionCatalogRefreshTokens.removeValue(forKey: activeCatalogKey)
        }
        actionCatalogRefreshSequence &+= 1
        let reloadSequence = actionCatalogRefreshSequence
        let activeSnapshot = storeActionCatalogSnapshot(
            actionCatalog,
            forKey: activeCatalogKey,
            sourceFingerprint: Self.actionCatalogSourceFingerprint(
                localPath: localPath,
                localContentDigest: localParseResult?.contentDigest,
                globalConfigPath: globalConfigPath,
                globalContentDigest: globalParseResult.contentDigest,
                workspaceColorPaletteFingerprint: paletteFingerprint
            ),
            notifyActiveChange: false
        )
        loadedActionCatalogSnapshot = activeSnapshot
        resolveActionCatalogFreshWaiters(
            key: activeCatalogKey,
            completedRefreshSequence: reloadSequence,
            snapshot: activeSnapshot
        )
        if activeCatalogKey != globalCatalogKey {
            let globalSnapshot = storeActionCatalogSnapshot(
                resolveActionCatalog(
                    localConfig: nil,
                    localIssue: nil,
                    localPath: nil,
                    globalConfig: globalConfig,
                    globalIssue: globalParseResult.issue
                ),
                forKey: globalCatalogKey,
                sourceFingerprint: globalSourceFingerprint,
                notifyActiveChange: false
            )
            resolveActionCatalogFreshWaiters(
                key: globalCatalogKey,
                completedRefreshSequence: reloadSequence,
                snapshot: globalSnapshot
            )
        }
        lastLoadAllGlobalSourceFingerprint = globalSourceFingerprint
        for key in Array(actionCatalogFreshWaiters.keys) {
            scheduleActionCatalogRefreshForFreshWaitersIfNeeded(key: key)
        }
        let commands = actionCatalog.loadedCommands
        let sourcePaths = actionCatalog.commandSourcePaths
        let resolvedActions = actionCatalog.loadedActions
        let resolvedActionLookup = Dictionary(
            uniqueKeysWithValues: resolvedActions.map { ($0.id, $0) }
        )
        let localHookPaths = resolvedLocalNotificationHookPaths(fallbackLocalPath: localPath)
        let localHookParseResults = localHookPaths.map { path in
            (path: path, result: parseConfig(at: path))
        }
        var issues = actionCatalog.configurationIssues
        for hookParseResult in localHookParseResults {
            guard hookParseResult.path != localPath,
                  let issue = hookParseResult.result.issue else { continue }
            issues.append(issue)
        }
        // Local config takes precedence
        if let localConfig {
            if let contextMenu = localConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = localPath
            }
            if let menuSectionOrder = localConfig.ui?.newWorkspace?.menuSectionOrder {
                configuredNewWorkspaceMenuSectionOrder = menuSectionOrder
            }
            if let buttons = localConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = localPath
            }
        }

        // Global config fills in the rest
        if let globalConfig {
            if configuredNewWorkspaceContextMenu == nil,
               let contextMenu = globalConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceMenuSectionOrder == nil,
               let menuSectionOrder = globalConfig.ui?.newWorkspace?.menuSectionOrder {
                configuredNewWorkspaceMenuSectionOrder = menuSectionOrder
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = globalConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = globalConfigPath
            }
        }
        let configuredButtons = configuredSurfaceTabBarButtons ?? CmuxSurfaceTabBarButton.defaults
        let defaultResolvedButtons = (try? CmuxSurfaceTabBarButton.defaults.map {
            try $0.resolved(actions: resolvedActionLookup, codingPath: [])
        }) ?? [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
            .builtIn(.splitRight),
            .builtIn(.splitDown)
        ]
        let resolvedButtons = resolvedSurfaceTabBarButtons(
            configuredButtons,
            actions: resolvedActionLookup,
            settingName: "ui.surfaceTabBar.buttons"
        ) ?? ResolvedSurfaceTabBarButtons(
            buttons: defaultResolvedButtons,
            terminalCommandSourcePaths: [:]
        )
        let resolvedWorkspaceButtons = resolvedSurfaceTabBarWorkspaceCommands(
            resolvedButtons.buttons,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceContextMenuItems = appendingAutoNewWorkspaceMenuActions(
            to: resolvedConfigContextMenuItems(
                configuredNewWorkspaceContextMenu ?? Self.defaultNewWorkspaceContextMenu,
                actions: resolvedActionLookup,
                commands: commands,
                sourcePaths: sourcePaths,
                settingName: "ui.newWorkspace.contextMenu",
                settingSourcePath: configuredNewWorkspaceContextMenuSourcePath
            ),
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNotificationHooks = resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localHookParseResults.compactMap { entry in
                entry.result.config.map { (path: entry.path, config: $0) }
            }
        )
        loadedCommands = commands
        loadedActions = resolvedActions
        commandSourcePaths = sourcePaths
        actionLookup = resolvedActionLookup
        newWorkspaceActionID = actionCatalog.configuredNewWorkspaceActionID
        newWorkspaceActionSourcePath = actionCatalog.configuredNewWorkspaceActionSourcePath
        newWorkspaceCommandName = actionCatalog.configuredNewWorkspaceCommandName
        newWorkspaceContextMenuItems = resolvedNewWorkspaceContextMenuItems.items
        newWorkspaceContextMenuIsConfigured = configuredNewWorkspaceContextMenu != nil
        newWorkspaceMenuSectionOrder = configuredNewWorkspaceMenuSectionOrder ?? .default
        agentChat = CmuxAgentChatConfiguration.resolved(
            local: localConfig?.agentChat, global: globalConfig?.agentChat,
            localSourcePath: localConfig?.agentChat == nil ? nil : localPath, globalSourcePath: globalConfig?.agentChat == nil ? nil : globalConfigPath
        )
        let resolvedGroupConfigs = resolveWorkspaceGroupConfigsFromLayers(
            localConfig: localConfig,
            globalConfig: globalConfig,
            localPath: localPath,
            globalPath: globalConfigPath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            issues: &issues
        )
        workspaceGroupConfigs = resolvedGroupConfigs
        surfaceTabBarButtonSourcePath = configuredSurfaceTabBarButtonSourcePath
        surfaceTabBarCommandSourcePaths = resolvedButtons.terminalCommandSourcePaths
        surfaceTabBarWorkspaceCommands = resolvedWorkspaceButtons.workspaceCommands
        surfaceTabBarButtons = resolvedWorkspaceButtons.buttons
        notificationHooks = resolvedNotificationHooks
        resolvedNewWorkspaceActionCache = actionCatalog.resolvedNewWorkspaceAction
        resolvedNewWorkspaceCommandCache = actionCatalog.resolvedNewWorkspaceCommand
        issues.append(contentsOf: resolvedNewWorkspaceContextMenuItems.issues)
        configurationIssues = issues
        if fileWatchingEnabled {
            updateLocalHookFileWatchers(
                paths: localHookPaths,
                primaryLocalPath: localPath
            )
        }
        applySurfaceTabBarButtonsToCurrentManager()
        configRevision &+= 1
        // Keep the selected palette hot. Other workspace and panel catalogs
        // load lazily through `freshActionCatalogSnapshot`, so one config save
        // never fans out into an app-wide filesystem scan.
        prewarmTrackedActionCatalogDirectories()
    }

    private func resolvedLocalNotificationHookPaths(fallbackLocalPath: String?) -> [String] {
        if let searchDirectory = localConfigSearchDirectory {
            var paths = findCmuxConfigHierarchy(startingFrom: searchDirectory)
            if let fallbackLocalPath, !paths.contains(fallbackLocalPath) {
                paths.append(fallbackLocalPath)
            }
            return paths
        }
        return fallbackLocalPath.map { [$0] } ?? []
    }

    private func resolveNotificationHooks(
        globalConfig: CmuxConfigFile?,
        localConfigs: [(path: String, config: CmuxConfigFile)]
    ) -> [CmuxResolvedNotificationHook] {
        var hooks: [CmuxResolvedNotificationHook] = []
        if let globalHooks = globalConfig?.notifications?.hooks {
            hooks.append(contentsOf: resolvedNotificationHooks(
                globalHooks,
                sourcePath: globalConfigPath
            ))
        }

        for entry in localConfigs {
            guard let notifications = entry.config.notifications else { continue }
            if notifications.hooksMode == .replace {
                hooks.removeAll()
            }
            if let localHooks = notifications.hooks {
                hooks.append(contentsOf: resolvedNotificationHooks(
                    localHooks,
                    sourcePath: entry.path
                ))
            }
        }
        return hooks
    }

    private func resolvedNotificationHooks(
        _ definitions: [CmuxNotificationHookDefinition],
        sourcePath: String
    ) -> [CmuxResolvedNotificationHook] {
        let cwd = CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)
        let canonicalSourcePath = Self.canonicalPath(sourcePath)
        let canonicalGlobalConfigPath = Self.canonicalPath(globalConfigPath)
        let isGlobalHook = canonicalSourcePath == canonicalGlobalConfigPath
        return definitions.compactMap { definition in
            guard definition.enabled else { return nil }
            let trustDescriptor: CmuxActionTrustDescriptor?
            if isGlobalHook {
                trustDescriptor = nil
            } else {
                trustDescriptor = CmuxActionTrustDescriptor(
                    actionID: definition.id,
                    kind: "notificationHook",
                    command: definition.command,
                    target: "notificationPolicy",
                    workspaceCommand: nil,
                    configPath: canonicalSourcePath,
                    projectRoot: Self.canonicalPath(cwd),
                    iconFingerprint: nil
                )
            }
            return CmuxResolvedNotificationHook(
                id: definition.id,
                command: definition.command,
                timeoutSeconds: definition.resolvedTimeoutSeconds,
                sourcePath: sourcePath,
                cwd: cwd,
                trustDescriptor: trustDescriptor
            )
        }
    }

    private func actionEntries(
        from actions: [String: CmuxConfigActionDefinition],
        sourcePath: String?
    ) -> [String: ActionEntry] {
        actions.mapValues { ActionEntry(definition: $0, sourcePath: sourcePath) }
    }

    private func mergedActionEntries(
        primary: [String: ActionEntry],
        fallback: [String: ActionEntry]
    ) -> [String: ActionEntry] {
        fallback.merging(primary) { _, primary in primary }
    }

    private func sanitizeConfigText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeConfigText(_ text: String, fallback: String) -> String {
        let sanitized = sanitizeConfigText(text)
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func resolvedActionRegistry(
        globalActions: [String: ActionEntry],
        localActions: [String: ActionEntry],
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String]
    ) -> [CmuxResolvedConfigAction] {
        var registry = Dictionary(
            uniqueKeysWithValues: CmuxSurfaceTabBarBuiltInAction.allCases.map {
                ($0.configID, CmuxResolvedConfigAction.builtIn($0))
            }
        )

        func apply(_ entries: [String: ActionEntry]) {
            for (id, entry) in entries {
                let registryID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
                if let existing = registry[registryID] {
                    guard let resolved = existing.applying(entry.definition, sourcePath: entry.sourcePath) else { continue }
                    registry[registryID] = resolved
                } else if let resolved = CmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: entry.definition,
                    sourcePath: entry.sourcePath
                ) {
                    registry[id] = resolved
                } else {
                    NSLog("[CmuxConfig] action '%@' ignored because it does not define a runnable action", id)
                }
            }
        }

        apply(globalActions)
        apply(localActions)

        for command in commands where registry[command.id] == nil {
            let sourcePath = commandSourcePaths[command.id]
            registry[command.id] = CmuxResolvedConfigAction(
                id: command.id,
                title: String(
                    localized: "command.cmuxConfig.customTitle",
                    defaultValue: "Custom: \(sanitizeConfigText(command.name))"
                ),
                subtitle: command.description.map { sanitizeConfigText($0) }
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.keywords ?? [],
                palette: true,
                shortcut: nil,
                icon: .symbol(command.workspace == nil ? "terminal" : "rectangle.stack.badge.plus"),
                tooltip: command.description,
                action: command.workspace == nil
                    ? .command(command.command ?? "")
                    : .workspaceCommand(command.name),
                confirm: command.confirm,
                terminalCommandTarget: command.workspace == nil ? .currentTerminal : nil,
                actionSourcePath: sourcePath,
                iconSourcePath: nil
            )
        }

        return registry.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        actions: [String: CmuxResolvedConfigAction],
        settingName: String
    ) -> ResolvedSurfaceTabBarButtons? {
        var resolvedButtons: [CmuxSurfaceTabBarButton] = []
        var terminalCommandSourcePaths: [String: String] = [:]
        resolvedButtons.reserveCapacity(buttons.count)

        for button in buttons {
            do {
                let resolved = try resolvedSurfaceTabBarButton(button, actions: actions)
                resolvedButtons.append(resolved.button)
                guard resolved.button.terminalCommand != nil else { continue }
                if let commandSourcePath = resolved.terminalCommandSourcePath {
                    terminalCommandSourcePaths[resolved.button.id] = commandSourcePath
                }
            } catch {
                NSLog("[CmuxConfig] %@ ignored: %@", settingName, String(describing: error))
                return nil
            }
        }

        return ResolvedSurfaceTabBarButtons(
            buttons: resolvedButtons,
            terminalCommandSourcePaths: terminalCommandSourcePaths
        )
    }

    private func resolvedSurfaceTabBarButton(
        _ button: CmuxSurfaceTabBarButton,
        actions: [String: CmuxResolvedConfigAction]
    ) throws -> ResolvedSurfaceTabBarButtonEntry {
        guard case .actionReference(let identifier) = button.action else {
            return ResolvedSurfaceTabBarButtonEntry(button: button, terminalCommandSourcePath: nil)
        }

        let resolvedIdentifier = canonicalActionID(identifier)
        if let entry = actions[resolvedIdentifier] {
            let resolvedButton = CmuxSurfaceTabBarButton(
                id: button.id,
                title: button.title ?? entry.title,
                icon: button.icon ?? entry.icon,
                tooltip: button.tooltip ?? entry.tooltip ?? entry.title,
                action: entry.action,
                confirm: button.confirm ?? entry.confirm,
                terminalCommandTarget: button.terminalCommandTarget ?? entry.terminalCommandTarget,
                actionSourcePath: entry.actionSourcePath,
                iconSourcePath: button.icon == nil ? entry.iconSourcePath : button.iconSourcePath
            )
            return ResolvedSurfaceTabBarButtonEntry(
                button: resolvedButton,
                terminalCommandSourcePath: resolvedButton.terminalCommand == nil ? nil : entry.actionSourcePath
            )
        }

        if let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return ResolvedSurfaceTabBarButtonEntry(
                button: CmuxSurfaceTabBarButton(
                    id: button.id,
                    title: button.title,
                    icon: button.icon,
                    tooltip: button.tooltip,
                    action: .builtIn(builtIn),
                    confirm: button.confirm,
                    terminalCommandTarget: button.terminalCommandTarget
                ),
                terminalCommandSourcePath: nil
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    private func applySurfaceTabBarButtonsToCurrentManager() {
        tabManager?.applySurfaceTabBarButtons(
            surfaceTabBarButtons,
            sourcePath: surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            terminalCommandSourcePaths: surfaceTabBarCommandSourcePaths,
            workspaceCommands: surfaceTabBarWorkspaceCommands
        )
    }

    private func resolvedSurfaceTabBarWorkspaceCommands(
        _ buttons: [CmuxSurfaceTabBarButton],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> (buttons: [CmuxSurfaceTabBarButton], workspaceCommands: [String: CmuxResolvedCommand]) {
        var visibleButtons: [CmuxSurfaceTabBarButton] = []
        var workspaceCommands: [String: CmuxResolvedCommand] = [:]
        visibleButtons.reserveCapacity(buttons.count)

        for button in buttons {
            guard let commandName = button.workspaceCommandName else {
                visibleButtons.append(button)
                continue
            }

            guard let command = resolvedWorkspaceCommand(
                named: commandName,
                settingName: "surfaceTabBarButtons action",
                commands: commands,
                sourcePaths: sourcePaths
            ) else {
                NSLog(
                    "[CmuxConfig] surfaceTabBarButtons action '%@' hidden because workspace command '%@' is unavailable",
                    button.id,
                    commandName
                )
                continue
            }

            visibleButtons.append(button)
            workspaceCommands[button.id] = command
        }

        return (visibleButtons, workspaceCommands)
    }

    func resolvedNewWorkspaceCommand() -> CmuxResolvedCommand? {
        resolvedNewWorkspaceCommandCache
    }

    func resolvedNewWorkspaceAction() -> CmuxResolvedConfigAction? {
        resolvedNewWorkspaceActionCache
    }

    func resolvedAction(id: String) -> CmuxResolvedConfigAction? {
        actionLookup[canonicalActionID(id)]
    }

    func paletteCustomActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    func shortcutActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.shortcut != nil && (builtInIDs.contains(action.id) || action.actionSourcePath != nil)
        }.sorted { lhs, rhs in
            let lhsPriority = builtInIDs.contains(lhs.id) ? 0 : 1
            let rhsPriority = builtInIDs.contains(rhs.id) ? 0 : 1
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedConfiguredNewWorkspaceAction(
        actionID: String?,
        actionSourcePath: String?,
        commandName: String?,
        commandSourcePath: String?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceActionResolution {
        if let actionID {
            let resolvedActionID = canonicalActionID(actionID)
            guard let action = actions[resolvedActionID] else {
                let issue = CmuxConfigIssue(
                    kind: .newWorkspaceActionNotFound,
                    settingName: "ui.newWorkspace.action",
                    commandName: actionID,
                    sourcePath: actionSourcePath
                )
                NSLog("[CmuxConfig] %@", issue.logMessage)
                return NewWorkspaceActionResolution(action: nil, command: nil, issue: issue)
            }
            if let actionCommandName = action.workspaceCommandName {
                let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                    named: actionCommandName,
                    settingName: "ui.newWorkspace.action",
                    settingSourcePath: action.actionSourcePath ?? actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                guard commandResolution.issue == nil else {
                    return NewWorkspaceActionResolution(
                        action: nil,
                        command: commandResolution.command,
                        issue: commandResolution.issue
                    )
                }
                return NewWorkspaceActionResolution(
                    action: action,
                    command: commandResolution.command,
                    issue: nil
                )
            }
            return NewWorkspaceActionResolution(action: action, command: nil, issue: nil)
        }

        guard let commandName else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: nil)
        }
        let commandResolution = resolvedConfiguredNewWorkspaceCommand(
            named: commandName,
            settingName: "newWorkspaceCommand",
            settingSourcePath: commandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )
        guard let command = commandResolution.command else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: commandResolution.issue)
        }
        return NewWorkspaceActionResolution(
            action: CmuxResolvedConfigAction(
                id: command.command.id,
                title: command.command.name,
                subtitle: command.command.description
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.command.keywords ?? [],
                palette: false,
                shortcut: nil,
                icon: .symbol("rectangle.stack.badge.plus"),
                tooltip: command.command.description,
                action: .workspaceCommand(command.command.name),
                confirm: command.command.confirm,
                terminalCommandTarget: nil,
                actionSourcePath: command.sourcePath,
                iconSourcePath: nil
            ),
            command: command,
            issue: nil
        )
    }

    /// Public lookup: given an anchor workspace's cwd, return the best-matching
    /// resolved group config. Matching uses auto-glob detection (keys with `*`
    /// or `?` are treated as fnmatch globs, others as path prefixes). Longest
    /// matching key wins. Returns nil when nothing matches.
    func resolveWorkspaceGroupConfig(forCwd cwd: String?) -> CmuxResolvedWorkspaceGroupConfig? {
        guard let cwd, !cwd.isEmpty, !workspaceGroupConfigs.isEmpty else { return nil }
        let normalizedCwd = Self.normalizeAbsolutePath(cwd)
        var best: (CmuxResolvedWorkspaceGroupConfig, Int)?
        for entry in workspaceGroupConfigs {
            guard Self.cwdEntryMatches(entry, cwd: normalizedCwd) else { continue }
            let score = entry.normalizedKey.count
            if best == nil || score > best!.1 {
                best = (entry, score)
            }
        }
        return best?.0
    }

    /// Replace a leading `~` with the user's home directory while preserving
    /// the rest of the pattern (including `*`/`?` glob characters). Unlike
    /// `normalizeAbsolutePath`, this skips `standardizingPath` so trailing
    /// glob segments aren't collapsed.
    private static func expandTildePreservingGlob(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = trimmed.dropFirst()
        return suffix.isEmpty ? home : home + String(suffix)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let suffix = trimmed.dropFirst()
            return suffix.isEmpty ? home : home + String(suffix)
        }
        return (trimmed as NSString).standardizingPath
    }

    private static func cwdEntryMatches(
        _ entry: CmuxResolvedWorkspaceGroupConfig,
        cwd: String
    ) -> Bool {
        let key = entry.normalizedKey
        if entry.isGlob {
            return fnmatchStyle(pattern: key, candidate: cwd)
        }
        if cwd == key { return true }
        // Root prefix `/` is a documented catch-all; without this branch
        // any non-root cwd would be tested against "//" and fail. Other
        // keys append `/` so `/Users/lawrence` doesn't also match
        // `/Users/lawrence-fork`.
        if key == "/" {
            return cwd.hasPrefix("/")
        }
        return cwd.hasPrefix(key + "/")
    }

    /// Minimal fnmatch: `*` matches any run of characters within a path segment
    /// (and across path separators); `?` matches a single character. Sufficient
    /// for the byCwd matching contract — full fnmatch features can come later.
    private static func fnmatchStyle(pattern: String, candidate: String) -> Bool {
        let p = Array(pattern)
        let s = Array(candidate)
        var pi = 0
        var si = 0
        var starP = -1
        var starS = -1
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi
                starS = si
                pi += 1
            } else if starP != -1 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private func resolveWorkspaceGroupConfigsFromLayers(
        localConfig: CmuxConfigFile?,
        globalConfig: CmuxConfigFile?,
        localPath: String?,
        globalPath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> [CmuxResolvedWorkspaceGroupConfig] {
        var resolved: [String: CmuxResolvedWorkspaceGroupConfig] = [:]
        if let globalEntries = globalConfig?.workspaceGroups?.byCwd {
            for (key, entry) in globalEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r
                }
            }
        }
        if let localEntries = localConfig?.workspaceGroups?.byCwd {
            for (key, entry) in localEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: localPath ?? globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r // local overrides global
                }
            }
        }
        return Array(resolved.values).sorted { $0.normalizedKey.count > $1.normalizedKey.count }
    }

    private func resolveWorkspaceGroupConfigEntry(
        key: String,
        entry: CmuxConfigWorkspaceGroupEntry,
        sourcePath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> CmuxResolvedWorkspaceGroupConfig? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isGlob = trimmed.contains("*") || trimmed.contains("?")
        // Expand `~` in both glob and prefix keys so a key like
        // `~/projects/*` matches workspace cwds that are already normalized to
        // absolute paths (`/Users/<you>/projects/foo`). Prefix keys also go
        // through `standardizingPath` so trailing `/.` and similar are
        // canonicalized.
        let normalizedKey = isGlob
            ? Self.expandTildePreservingGlob(trimmed)
            : Self.normalizeAbsolutePath(trimmed)
        let menuResolution = resolvedConfigContextMenuItems(
            entry.contextMenu,
            actions: actions,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "workspaceGroups.byCwd[\(key)].contextMenu",
            settingSourcePath: sourcePath
        )
        issues.append(contentsOf: menuResolution.issues)
        return CmuxResolvedWorkspaceGroupConfig(
            originalKey: trimmed,
            normalizedKey: normalizedKey,
            isGlob: isGlob,
            color: entry.color.map(sanitizeConfigText),
            iconSymbol: entry.icon.map(sanitizeConfigText),
            contextMenuItems: menuResolution.items,
            newWorkspacePlacement: WorkspaceGroupNewPlacement(rawString: entry.newWorkspacePlacement)
        )
    }

    private func resolvedConfigContextMenuItems(
        _ configuredItems: [CmuxConfigContextMenuItem]?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        settingName: String,
        settingSourcePath: String?
    ) -> ResolvedContextMenuItems {
        guard let configuredItems, !configuredItems.isEmpty else {
            return ResolvedContextMenuItems(items: [], issues: [])
        }
        var resolvedItems: [CmuxResolvedConfigContextMenuItem] = []
        var issues: [CmuxConfigIssue] = []
        resolvedItems.reserveCapacity(configuredItems.count)

        for (index, configuredItem) in configuredItems.enumerated() {
            let itemSettingName = "\(settingName)[\(index)]"
            switch configuredItem {
            case .separator:
                guard !resolvedItems.isEmpty else { continue }
                if let last = resolvedItems.last, case .separator = last {
                    continue
                }
                resolvedItems.append(.separator(id: "\(settingName).separator.\(index)"))
            case .action(let item):
                let resolvedActionID = canonicalActionID(item.action)
                guard let action = actions[resolvedActionID] else {
                    let issue = CmuxConfigIssue(
                        kind: .newWorkspaceActionNotFound,
                        settingName: itemSettingName,
                        commandName: item.action,
                        sourcePath: settingSourcePath
                    )
                    NSLog("[CmuxConfig] %@", issue.logMessage)
                    issues.append(issue)
                    continue
                }
                if let actionCommandName = action.workspaceCommandName {
                    let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                        named: actionCommandName,
                        settingName: itemSettingName,
                        settingSourcePath: action.actionSourcePath ?? settingSourcePath,
                        commands: commands,
                        sourcePaths: sourcePaths
                    )
                    if let issue = commandResolution.issue {
                        issues.append(issue)
                        continue
                    }
                    guard commandResolution.command != nil else {
                        continue
                    }
                }
                resolvedItems.append(
                    .action(
                        CmuxResolvedConfigMenuAction(
                            id: "\(settingName).\(index).\(action.id)",
                            title: sanitizeConfigText(item.title ?? action.title, fallback: action.id),
                            icon: item.icon ?? action.icon,
                            iconSourcePath: item.icon == nil ? action.iconSourcePath : settingSourcePath,
                            tooltip: (item.tooltip ?? action.tooltip).map(sanitizeConfigText),
                            action: action
                        )
                    )
                )
            }
        }

        if let last = resolvedItems.last, case .separator = last {
            resolvedItems.removeLast()
        }
        return ResolvedContextMenuItems(items: resolvedItems, issues: issues)
    }

    private func canonicalActionID(_ id: String) -> String {
        CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
    }

    /// Auto-offers qualifying actions (inline workspace actions by default, plus
    /// anything with `newWorkspaceMenu: true`) in the plus-button menu without
    /// requiring the user to hand-edit `ui.newWorkspace.contextMenu`. Explicitly
    /// listed actions are not duplicated; `newWorkspaceMenu: false` opts out.
    /// `workspaceCommand` actions get the same named-command validation the
    /// explicit menu path applies, so a dead reference surfaces as a config
    /// issue instead of a no-op menu item.
    private func appendingAutoNewWorkspaceMenuActions(
        to resolved: ResolvedContextMenuItems,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> ResolvedContextMenuItems {
        let existingActionIDs = Set(resolved.items.compactMap { item -> String? in
            if case .action(let menuAction) = item {
                return menuAction.action.id
            }
            return nil
        })
        let candidates = actions.values
            .filter { $0.wantsNewWorkspaceMenu && !existingActionIDs.contains($0.id) }
            .sorted {
                ($0.title, $0.id) < ($1.title, $1.id)
            }
        guard !candidates.isEmpty else { return resolved }

        var issues = resolved.issues
        var autoActions: [CmuxResolvedConfigAction] = []
        for action in candidates {
            if let commandName = action.workspaceCommandName {
                let resolution = resolvedConfiguredNewWorkspaceCommand(
                    named: commandName,
                    settingName: "ui.newWorkspace.contextMenu.auto.\(action.id)",
                    settingSourcePath: action.actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                if let issue = resolution.issue {
                    issues.append(issue)
                    continue
                }
                guard resolution.command != nil else { continue }
            }
            autoActions.append(action)
        }
        guard !autoActions.isEmpty else {
            return ResolvedContextMenuItems(items: resolved.items, issues: issues)
        }

        var items = resolved.items
        if let last = items.last, case .action = last {
            items.append(.separator(id: "ui.newWorkspace.contextMenu.auto.separator"))
        }
        items.append(contentsOf: autoActions.map { action in
            .action(
                CmuxResolvedConfigMenuAction(
                    id: "ui.newWorkspace.contextMenu.auto.\(action.id)",
                    title: sanitizeConfigText(action.title, fallback: action.id),
                    icon: action.icon,
                    iconSourcePath: action.iconSourcePath,
                    tooltip: action.tooltip.map(sanitizeConfigText),
                    action: action
                )
            )
        })
        return ResolvedContextMenuItems(items: items, issues: issues)
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        named commandName: String,
        settingName: String,
        settingSourcePath: String?,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: settingSourcePath
            )
        }
        guard command.workspace != nil else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: sourcePaths[command.id] ?? settingSourcePath
            )
        }
        return NewWorkspaceCommandResolution(
            command: CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id]),
            issue: nil
        )
    }

    private func newWorkspaceResolutionIssue(
        kind: CmuxConfigIssue.Kind,
        settingName: String,
        commandName: String?,
        sourcePath: String?
    ) -> NewWorkspaceCommandResolution {
        let issue = CmuxConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[CmuxConfig] %@", issue.logMessage)
        return NewWorkspaceCommandResolution(command: nil, issue: issue)
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String
    ) -> CmuxResolvedCommand? {
        resolvedWorkspaceCommand(
            named: commandName,
            settingName: settingName,
            commands: loadedCommands,
            sourcePaths: commandSourcePaths
        )
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> CmuxResolvedCommand? {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            NSLog("[CmuxConfig] %@ '%@' does not match any loaded command", settingName, commandName)
            return nil
        }
        guard command.workspace != nil else {
            NSLog("[CmuxConfig] %@ '%@' must reference a workspace command", settingName, commandName)
            return nil
        }
        return CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id])
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ParsedConfigResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            parsedConfigCache.removeValue(forKey: path)
            return ParsedConfigResult(
                config: nil,
                issue: nil,
                contentDigest: "<missing>"
            )
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date
        let workspaceColorPalette = WorkspaceTabColorSettings.resolvedPaletteMap()
        let paletteFingerprint = WorkspaceTabColorSettings.paletteCacheFingerprint(
            workspaceColorPalette
        )

        if let cached = parsedConfigCache[path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate,
           cached.workspaceColorPaletteFingerprint == paletteFingerprint {
            return ParsedConfigResult(
                config: cached.config,
                issue: cached.issue,
                contentDigest: cached.contentDigest
            )
        }

        let rawData = fileManager.contents(atPath: path)
        let contentDigest = rawData.map(Self.actionCatalogContentDigest) ?? "<unreadable>"
        guard let data = rawData,
              !data.isEmpty else {
            let issue = schemaIssue(path: path, message: "cmux.json is empty")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                contentDigest: contentDigest,
                config: nil,
                issue: issue
            )
            return ParsedConfigResult(
                config: nil,
                issue: issue,
                contentDigest: contentDigest
            )
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            let issue = schemaIssue(path: path, message: "JSONC preprocessing failed: \(schemaErrorMessage(error))")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                contentDigest: contentDigest,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] JSONC preprocessing error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(
                config: nil,
                issue: issue,
                contentDigest: contentDigest
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.cmuxWorkspaceColorDefaults] = workspaceColorPalette
            let config = try decoder.decode(CmuxConfigFile.self, from: sanitized)
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                contentDigest: contentDigest,
                config: config,
                issue: nil
            )
            return ParsedConfigResult(
                config: config,
                issue: nil,
                contentDigest: contentDigest
            )
        } catch {
            let issue = schemaIssue(path: path, message: schemaErrorMessage(error))
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                contentDigest: contentDigest,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] parse error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(
                config: nil,
                issue: issue,
                contentDigest: contentDigest
            )
        }
    }

    private func schemaIssue(path: String, message: String) -> CmuxConfigIssue {
        CmuxConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    private func schemaErrorMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let path = schemaCodingPath(context.codingPath + [key])
            let detail = sanitizeConfigText(context.debugDescription)
            return "\(path): \(detail)"
        case DecodingError.dataCorrupted(let context):
            return schemaErrorMessage(context)
        default:
            let message = sanitizeConfigText(error.localizedDescription)
            return message.isEmpty ? String(describing: error) : message
        }
    }

    private func schemaErrorMessage(_ context: DecodingError.Context) -> String {
        let path = schemaCodingPath(context.codingPath)
        let detail = sanitizeConfigText(context.debugDescription)
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    private func schemaCodingPath(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return path.isEmpty ? "root" : path
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func updateLocalHookFileWatchers(
        paths: [String],
        primaryLocalPath: String?
    ) {
        let desiredPaths = Set(paths.filter { path in
            path != primaryLocalPath && FileManager.default.fileExists(atPath: path)
        })
        for path in Array(hookWatchers.keys) where !desiredPaths.contains(path) {
            stopLocalHookFileWatcher(at: path)
        }
        for path in desiredPaths where hookWatchers[path] == nil {
            startLocalHookFileWatcher(at: path)
        }
    }

    private func startLocalHookFileWatcher(at path: String) {
        let watcher = FileWatcher(path: path)
        hookWatchers[path] = watcher
        let events = watcher.events
        hookWatchTasks[path] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopLocalHookFileWatcher(at path: String) {
        hookWatchTasks.removeValue(forKey: path)?.cancel()
        hookWatchers.removeValue(forKey: path)
    }

    private func stopLocalHookFileWatchers() {
        hookWatchTasks.values.forEach { $0.cancel() }
        hookWatchTasks.removeAll()
        hookWatchers.removeAll()
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let configDirectory = (path as NSString).deletingLastPathComponent
        let fs = FileManager.default
        let dirPath: String
        if fs.fileExists(atPath: configDirectory) {
            dirPath = configDirectory
        } else if let searchDirectory = localConfigSearchDirectory,
                  fs.fileExists(atPath: searchDirectory) {
            dirPath = searchDirectory
        } else {
            dirPath = (configDirectory as NSString).deletingLastPathComponent
        }
        let eventHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.handleLocalDirectoryWatchEvent()
            }
        }

        guard let primaryWatch = startLocalDirectoryWatchSource(at: dirPath, eventHandler: eventHandler) else {
            return
        }
        localFileWatchSource = primaryWatch.source
        localFileDescriptor = primaryWatch.fileDescriptor

        if let searchDirectory = localConfigSearchDirectory,
           fs.fileExists(atPath: configDirectory),
           searchDirectory != dirPath,
           let fallbackWatch = startLocalDirectoryWatchSource(at: searchDirectory, eventHandler: eventHandler) {
            localFallbackDirectoryWatchSource = fallbackWatch.source
            localFallbackDirectoryDescriptor = fallbackWatch.fileDescriptor
        }
    }

    private func startLocalDirectoryWatchSource(
        at dirPath: String,
        eventHandler: @escaping () -> Void
    ) -> (source: DispatchSourceFileSystemObject, fileDescriptor: Int32)? {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return (source, fd)
    }

    private func handleLocalDirectoryWatchEvent() {
        if let searchDirectory = localConfigSearchDirectory {
            let resolvedPath = resolvedLocalConfigPath(startingFrom: searchDirectory)
            if resolvedPath != localConfigPath {
                localConfigPath = resolvedPath
            }
        }
        guard let configPath = localConfigPath else { return }
        let configDirectory = (configPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configPath) ||
            FileManager.default.fileExists(atPath: configDirectory) else { return }
        // File or its parent directory appeared — switch to file-level watching.
        stopLocalFileWatcher()
        loadAll()
        startLocalFileWatcher()
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        stopLocalHookFileWatchers()
        if let source = localFallbackDirectoryWatchSource {
            source.cancel()
            localFallbackDirectoryWatchSource = nil
        }
        localFileDescriptor = -1
        localFallbackDirectoryDescriptor = -1
    }

    // MARK: - File watching (global)

    /// Watches the global config via ``CmuxFileWatch/FileWatcher``, which handles
    /// inode reattachment and nearest-existing-ancestor recovery internally; each
    /// change reloads. Ensures the config directory exists first (the previous
    /// directory-watcher created it).
    private func startGlobalWatching() {
        stopGlobalWatching()
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let watcher = FileWatcher(path: globalConfigPath)
        globalWatcher = watcher
        let events = watcher.events
        globalWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopGlobalWatching() {
        globalWatchTask?.cancel()
        globalWatchTask = nil
        globalWatcher = nil
    }
}

extension CmuxConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
