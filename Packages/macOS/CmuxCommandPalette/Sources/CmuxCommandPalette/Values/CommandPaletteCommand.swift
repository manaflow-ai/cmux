import Foundation

/// One runnable palette command: identity, display strings, search keywords,
/// and the action executed when the command is activated.
public struct CommandPaletteCommand: Identifiable {
    /// Stable command identifier.
    public let id: String
    /// Tie-break rank; lower sorts first at equal score.
    public let rank: Int
    /// Display title.
    public let title: String
    /// Display subtitle.
    public let subtitle: String
    /// Optional keyboard-shortcut hint shown trailing the row.
    public let shortcutHint: String?
    /// Optional kind label (for example a switcher row's surface kind).
    public let kindLabel: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
    /// Static arguments accepted by the action.
    public let arguments: [CmuxActionArgumentDefinition]
    /// The action executor shared by presentation adapters.
    private let handler: CmuxActionHandler

    /// Creates a command.
    public init(
        id: String,
        rank: Int,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        arguments: [CmuxActionArgumentDefinition] = [],
        handler: @escaping CmuxActionHandler
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.arguments = arguments
        self.handler = handler
    }

    /// Compatibility initializer for zero-argument palette commands.
    public init(
        id: String,
        rank: Int,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        action: @escaping @MainActor () -> Void
    ) {
        self.init(
            id: id,
            rank: rank,
            title: title,
            subtitle: subtitle,
            shortcutHint: shortcutHint,
            kindLabel: kindLabel,
            keywords: keywords,
            dismissOnRun: dismissOnRun,
            handler: { _ in
                action()
                return .completed
            }
        )
    }

    /// Validates statically declared arguments and executes the action.
    @MainActor
    public func execute(_ invocation: CmuxActionInvocation) -> CmuxActionExecutionResult {
        let knownArgumentNames = Set(arguments.map(\.name))
        let unknownArgumentNames = invocation.arguments.keys.filter { !knownArgumentNames.contains($0) }.sorted()
        if !unknownArgumentNames.isEmpty {
            return .invalidArguments(unknownArgumentNames)
        }

        if invocation.source == .automation {
            let missingArguments = arguments.filter { argument in
                guard argument.required else { return false }
                guard let value = invocation.arguments[argument.name] else { return true }
                return value.isEmpty && !argument.allowsEmpty
            }
            if !missingArguments.isEmpty {
                return .requiresArguments(missingArguments)
            }
        }

        let invalidValueArguments = arguments.compactMap { argument -> String? in
            guard let value = invocation.arguments[argument.name] else { return nil }
            if value.isEmpty && !argument.allowsEmpty {
                return argument.name
            }
            switch argument.valueType {
            case .string, .path:
                return nil
            case .boolean:
                return invocation.bool(argument.name) == nil ? argument.name : nil
            }
        }.sorted()
        if !invalidValueArguments.isEmpty {
            return .invalidArgumentValues(invalidValueArguments)
        }

        var normalizedArguments = invocation.arguments
        for argument in arguments where argument.valueType == .path {
            guard let rawPath = normalizedArguments[argument.name], !rawPath.isEmpty else { continue }
            let expandedPath = NSString(string: rawPath).expandingTildeInPath
            let resolvedPath: String
            if NSString(string: expandedPath).isAbsolutePath {
                resolvedPath = expandedPath
            } else if let workingDirectory = invocation.workingDirectory {
                resolvedPath = URL(
                    fileURLWithPath: expandedPath,
                    relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
                ).path
            } else {
                resolvedPath = expandedPath
            }
            normalizedArguments[argument.name] = URL(
                fileURLWithPath: resolvedPath,
                isDirectory: true
            ).standardizedFileURL.path
        }

        return handler(CmuxActionInvocation(
            source: invocation.source,
            arguments: normalizedArguments,
            workingDirectory: invocation.workingDirectory
        ))
    }

    /// Legacy command-palette closure used by existing view code.
    @MainActor
    public var action: () -> Void {
        {
            _ = execute(CmuxActionInvocation(source: .commandPalette))
        }
    }

    /// Texts the search corpus indexes for this command.
    public var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}
