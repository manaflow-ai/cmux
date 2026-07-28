import CmuxCommandPalette
import Foundation

/// One conversation fork, including the destination harness and layout target.
struct AgentConversationForkRequest: Equatable, Sendable {
    static let harnessArgumentName = "harness"
    static let destinationArgumentName = "destination"

    enum TargetHarness: String, CaseIterable, Identifiable, Sendable {
        case current
        case claude
        case codex
        case opencode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .current:
                String(localized: "forkConversation.harness.current", defaultValue: "Current Harness")
            case .claude:
                String(localized: "forkConversation.harness.claude", defaultValue: "Claude Code")
            case .codex:
                String(localized: "forkConversation.harness.codex", defaultValue: "Codex")
            case .opencode:
                String(localized: "forkConversation.harness.opencode", defaultValue: "OpenCode")
            }
        }

        func usesNativeFork(for sourceKind: RestorableAgentKind) -> Bool {
            self == .current || rawValue == sourceKind.rawValue
        }

        func startupCommand(handoffMessage: String) -> String? {
            switch self {
            case .current:
                nil
            case .claude:
                "claude \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            case .codex:
                "codex \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            case .opencode:
                "opencode --prompt \(TerminalStartupShellQuoting.singleQuoted(handoffMessage))"
            }
        }
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

    static var commandPaletteChoiceArguments: [CommandPaletteChoiceArgument] {
        [
            CommandPaletteChoiceArgument(
                name: harnessArgumentName,
                title: String(localized: "forkConversation.argument.harness", defaultValue: "Harness"),
                choices: TargetHarness.allCases.map {
                    .init(value: $0.rawValue, title: $0.title)
                }
            ),
            CommandPaletteChoiceArgument(
                name: destinationArgumentName,
                title: String(localized: "forkConversation.argument.destination", defaultValue: "Destination"),
                choices: AgentConversationForkDestination.allCases.map {
                    .init(value: $0.rawValue, title: $0.settingsTitle)
                }
            ),
        ]
    }

    init?(arguments: [String: String]) {
        guard let harnessValue = arguments[Self.harnessArgumentName],
              let targetHarness = TargetHarness(rawValue: harnessValue),
              let destinationValue = arguments[Self.destinationArgumentName],
              let destination = AgentConversationForkDestination(rawValue: destinationValue) else {
            return nil
        }
        self.init(targetHarness: targetHarness, destination: destination)
    }

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
