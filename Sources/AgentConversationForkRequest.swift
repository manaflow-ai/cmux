import CmuxCommandPalette
import Foundation

/// One requested agent-conversation fork, including its target harness and layout destination.
struct AgentConversationForkRequest: Equatable, Sendable {
    /// The harness that should own the forked conversation.
    enum TargetHarness: String, CaseIterable, Identifiable, Sendable {
        case current
        case claude
        case codex
        case opencode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .current:
                return String(localized: "forkConversation.harness.current", defaultValue: "Current Harness")
            case .claude:
                return String(localized: "forkConversation.harness.claude", defaultValue: "Claude Code")
            case .codex:
                return String(localized: "forkConversation.harness.codex", defaultValue: "Codex")
            case .opencode:
                return String(localized: "forkConversation.harness.opencode", defaultValue: "OpenCode")
            }
        }

        fileprivate func usesNativeFork(for sourceKind: RestorableAgentKind) -> Bool {
            self == .current || rawValue == sourceKind.rawValue
        }

        fileprivate func startupCommand(
            sourceSnapshot: SessionRestorableAgentSnapshot
        ) -> String? {
            guard !usesNativeFork(for: sourceSnapshot.kind) else { return nil }

            let lookupCommand = [
                "cmux sessions list --agent",
                Self.shellSingleQuoted(sourceSnapshot.kind.rawValue),
                "--session",
                Self.shellSingleQuoted(sourceSnapshot.sessionId),
                "--json",
            ].joined(separator: " ")
            let prompt = String(
                localized: "forkConversation.crossHarness.prompt",
                defaultValue: "Continue the latest unfinished request from the \(sourceSnapshot.agentDisplayName) session \(sourceSnapshot.sessionId). Before acting, run `\(lookupCommand)` and read the transcript path it returns. If no transcript is readable, use the source harness's export command. Explain any missing context before changing files."
            )

            switch self {
            case .current:
                return nil
            case .claude:
                return "claude \(Self.shellSingleQuoted(prompt))"
            case .codex:
                return "codex \(Self.shellSingleQuoted(prompt))"
            case .opencode:
                return "opencode --prompt \(Self.shellSingleQuoted(prompt))"
            }
        }

        private static func shellSingleQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    static let harnessArgumentName = "harness"
    static let destinationArgumentName = "destination"

    static var commandPaletteArguments: [CmuxActionArgumentDefinition] {
        [
            CmuxActionArgumentDefinition(
                name: harnessArgumentName,
                title: String(localized: "forkConversation.argument.harness", defaultValue: "Harness"),
                choices: TargetHarness.allCases.map {
                    CmuxActionArgumentDefinition.Choice(value: $0.rawValue, title: $0.title)
                }
            ),
            CmuxActionArgumentDefinition(
                name: destinationArgumentName,
                title: String(localized: "forkConversation.argument.destination", defaultValue: "Destination"),
                choices: AgentConversationForkDestination.allCases.map {
                    CmuxActionArgumentDefinition.Choice(value: $0.rawValue, title: $0.settingsTitle)
                }
            ),
        ]
    }

    let targetHarness: TargetHarness
    let destination: AgentConversationForkDestination

    init(
        targetHarness: TargetHarness,
        destination: AgentConversationForkDestination
    ) {
        self.targetHarness = targetHarness
        self.destination = destination
    }

    init?(invocation: CmuxActionInvocation) {
        guard let harnessValue = invocation.string(Self.harnessArgumentName),
              let targetHarness = TargetHarness(rawValue: harnessValue),
              let destinationValue = invocation.string(Self.destinationArgumentName),
              let destination = AgentConversationForkDestination(rawValue: destinationValue) else {
            return nil
        }
        self.init(targetHarness: targetHarness, destination: destination)
    }

    /// Returns a startup-input override for a cross-harness handoff.
    ///
    /// `nil` means the request should use the source harness's native fork command.
    func startupInputOverride(
        sourceSnapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        targetHarness.startupCommand(sourceSnapshot: sourceSnapshot).map { $0 + "\n" }
    }
}
