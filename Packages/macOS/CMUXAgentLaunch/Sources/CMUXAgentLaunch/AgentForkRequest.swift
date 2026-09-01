import Foundation

/// Primitive input for constructing one shell-free fork invocation.
///
/// The request deliberately carries no app or registry types. Callers map
/// their persisted snapshot/registration models into this value, then share
/// the same launcher, built-in, and custom-template rules everywhere.
public struct AgentForkRequest: Sendable, Equatable {
    /// A registry fork template after its metadata has been reduced to values.
    public struct CustomTemplate: Sendable, Equatable {
        /// The template containing `{{executable}}`, `{{sessionId}}`, and related tokens.
        public let command: String
        /// The executable used when the captured launch has no argv[0].
        public let defaultExecutable: String
        /// The optional persisted session directory, already expanded by the caller.
        public let sessionDirectory: String?

        /// Creates a custom fork template.
        public init(
            command: String,
            defaultExecutable: String,
            sessionDirectory: String? = nil
        ) {
            self.command = command
            self.defaultExecutable = defaultExecutable
            self.sessionDirectory = sessionDirectory
        }
    }

    /// Agent kind used for built-in fork rules.
    public let kind: String
    /// Checkpoint/session identifier embedded in the fork argv.
    public let checkpointID: String
    /// Captured launch metadata, when available.
    public let launchCommand: AgentLaunchCommand?
    /// Destination working directory used by custom `{{cwd}}` templates.
    public let workingDirectory: String?
    /// Captured Claude permission mode, when applicable.
    public let observedPermissionMode: String?
    /// Whether the kind is a custom registration and must not use built-in fallbacks.
    public let isCustomKind: Bool
    /// Optional registry-owned template.
    public let customTemplate: CustomTemplate?

    /// Creates one fork planning request.
    public init(
        kind: String,
        checkpointID: String,
        launchCommand: AgentLaunchCommand? = nil,
        workingDirectory: String? = nil,
        observedPermissionMode: String? = nil,
        isCustomKind: Bool = false,
        customTemplate: CustomTemplate? = nil
    ) {
        self.kind = kind
        self.checkpointID = checkpointID
        self.launchCommand = launchCommand
        self.workingDirectory = workingDirectory
        self.observedPermissionMode = observedPermissionMode
        self.isCustomKind = isCustomKind
        self.customTemplate = customTemplate
    }

    /// Builds sanitized argv, or `nil` when no safe fork form is available.
    public func forkArguments() -> [String]? {
        let forkArgv = AgentForkArgv()
        switch forkArgv.launcherResolution(
            launcher: launchCommand?.launcher,
            sessionId: checkpointID,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? []
        ) {
        case .resolved(let argv):
            return argv
        case .passthrough:
            break
        }

        if let customTemplate {
            let arguments = templateArguments(customTemplate)
            return arguments.isEmpty ? nil : arguments
        }
        if isCustomKind {
            return nil
        }
        return forkArgv.builtInKind(
            kind: kind,
            sessionId: checkpointID,
            executablePath: launchCommand?.executablePath,
            arguments: launchCommand?.arguments ?? [],
            observedPermissionMode: observedPermissionMode
        )
    }

    private func templateArguments(_ template: CustomTemplate) -> [String] {
        let parts = splitShellWords(template.command)
        guard !parts.isEmpty else { return [] }
        let originalExecutable = commandExecutable(fallbackExecutable: template.defaultExecutable)
        let replacements: [String: String] = [
            "sessionId": checkpointID,
            "sessionPath": checkpointID,
            "executable": originalExecutable,
            "cwd": normalized(workingDirectory ?? launchCommand?.workingDirectory) ?? "",
            "sessionDir": template.sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        for part in parts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    private func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    private func splitShellWords(_ command: String) -> [String] {
        enum Quote { case single, double }
        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        finishWord()
        return words
    }

    private func commandExecutable(fallbackExecutable: String) -> String {
        let arguments = launchCommand?.arguments ?? []
        return normalized(launchCommand?.executablePath)
            ?? normalized(arguments.first)
            ?? fallbackExecutable
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
