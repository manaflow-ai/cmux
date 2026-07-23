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

        fileprivate func startupCommand(handoffMessage: String) -> String? {
            switch self {
            case .current:
                return nil
            case .claude:
                return "claude \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            case .codex:
                return "codex \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            case .opencode:
                return "opencode --prompt \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            }
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

    /// Returns a startup command for a cross-harness handoff.
    ///
    /// `nil` means the request should use the source harness's native fork command.
    func startupCommandOverride(
        sourceSnapshot: SessionRestorableAgentSnapshot,
        exportService: AgentConversationExportService = .live
    ) async throws -> String? {
        guard !targetHarness.usesNativeFork(for: sourceSnapshot.kind) else {
            return nil
        }
        let handoffMessage = try await exportService.message(for: sourceSnapshot)
        return targetHarness.startupCommand(handoffMessage: handoffMessage)
    }
}
