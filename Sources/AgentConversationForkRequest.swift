import CmuxCommandPalette
import Foundation

/// One conversation fork, including the destination harness and layout target.
struct AgentConversationForkRequest: Equatable, Sendable {
    static let harnessArgumentName = "harness"
    static let destinationArgumentName = "destination"

    typealias TargetHarness = AgentConversationForkTargetHarness

    let target: AgentConversationForkTarget
    let destination: AgentConversationForkDestination

    var targetHarness: TargetHarness { target.harness }

    init(
        target: AgentConversationForkTarget,
        destination: AgentConversationForkDestination
    ) {
        self.target = target
        self.destination = destination
    }

    /// Convenience for native and deterministic tests. Installed UI targets use
    /// the resolved-target initializer so their discovered executable is retained.
    init(
        targetHarness: TargetHarness,
        destination: AgentConversationForkDestination
    ) {
        self.init(
            target: .canonical(targetHarness),
            destination: destination
        )
    }

    static func sameHarness(
        destination: AgentConversationForkDestination
    ) -> AgentConversationForkRequest {
        AgentConversationForkRequest(
            target: .current,
            destination: destination
        )
    }

    static func commandPaletteChoiceArguments(
        targets: [AgentConversationForkTarget]
    ) -> [CommandPaletteChoiceArgument] {
        [
            CommandPaletteChoiceArgument(
                name: harnessArgumentName,
                title: String(localized: "forkConversation.argument.harness", defaultValue: "Harness"),
                choices: targets.filter { $0.harness != .current }.map {
                    .init(value: $0.harness.rawValue, title: $0.title)
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

    static func commandPaletteChoiceArguments(
        targetHarnesses: [TargetHarness]
    ) -> [CommandPaletteChoiceArgument] {
        commandPaletteChoiceArguments(
            targets: targetHarnesses.map { .canonical($0) }
        )
    }

    init?(
        arguments: [String: String],
        installedTargets: [AgentConversationForkTarget]
    ) {
        guard let harnessValue = arguments[Self.harnessArgumentName],
              let targetHarness = TargetHarness(rawValue: harnessValue),
              let target = installedTargets.first(where: { $0.harness == targetHarness }),
              let destinationValue = arguments[Self.destinationArgumentName],
              let destination = AgentConversationForkDestination(rawValue: destinationValue) else {
            return nil
        }
        self.init(target: target, destination: destination)
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
        let validatedTarget = try await target.validatedForTransfer()
        let handoffMessage = try await exportService.message(for: sourceSnapshot)
        guard validatedTarget.executableIdentityIsCurrent() else {
            throw AgentConversationForkRequestError.targetExecutableChanged
        }
        return validatedTarget.startupCommand(handoffMessage: handoffMessage)
    }
}
