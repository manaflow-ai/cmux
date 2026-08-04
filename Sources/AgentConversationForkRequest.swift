import CmuxCommandPalette
import Foundation

/// One conversation fork, including the destination harness and layout target.
struct AgentConversationForkRequest: Equatable, Sendable {
    static let harnessArgumentName = "harness"
    static let destinationArgumentName = "destination"

    typealias TargetHarness = AgentConversationForkTargetHarness

    let targetHarness: TargetHarness
    let destination: AgentConversationForkDestination

    init(
        targetHarness: TargetHarness,
        destination: AgentConversationForkDestination
    ) {
        self.targetHarness = targetHarness
        self.destination = destination
    }

    static func sameHarness(
        destination: AgentConversationForkDestination
    ) -> AgentConversationForkRequest {
        AgentConversationForkRequest(
            targetHarness: .current,
            destination: destination
        )
    }

    static var commandPaletteChoiceArguments: [CommandPaletteChoiceArgument] {
        [
            CommandPaletteChoiceArgument(
                name: harnessArgumentName,
                title: String(localized: "forkConversation.argument.harness", defaultValue: "Harness"),
                choices: TargetHarness.allCases.filter { $0 != .current }.map {
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
        forceConversationTransfer: Bool = false,
        exportService: AgentConversationExportService = .live
    ) async throws -> String? {
        guard targetHarness != .current,
              forceConversationTransfer
                || !targetHarness.usesNativeFork(for: sourceSnapshot.kind) else {
            return nil
        }
        let handoffMessage = try await exportService.message(for: sourceSnapshot)
        return targetHarness.startupCommand(handoffMessage: handoffMessage)
    }
}
