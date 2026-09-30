import Foundation

extension CMUXCLI {
    /// The localized reason a verb that only drove a feature of the deleted
    /// legacy app has no cmux-next equivalent, or nil for any other verb.
    /// Removed verbs keep a typed error, so scripts learn why instead of
    /// seeing "Unknown command".
    static func removedCommandReason(_ command: String) -> String? {
        switch command {
        case "canvas":
            return String(localized: "cli.removed.reason.canvas", defaultValue: "canvas layout was removed", bundle: .cmuxCLI)
        case "debug-terminals", "simulate-sidebar-drag":
            return String(localized: "cli.removed.reason.debugMethods", defaultValue: "debug methods of the old app are not part of cmux-next", bundle: .cmuxCLI)
        case "iroh-diag":
            return String(localized: "cli.removed.reason.irohDiag", defaultValue: "Iroh diagnostics of the old app are not part of cmux-next", bundle: .cmuxCLI)
        case "ios", "simulator":
            return String(localized: "cli.removed.reason.simulator", defaultValue: "the simulator pane is not part of cmux-next", bundle: .cmuxCLI)
        case "project":
            return String(localized: "cli.removed.reason.project", defaultValue: "the project pane is not part of cmux-next", bundle: .cmuxCLI)
        case "refresh-surfaces":
            return String(localized: "cli.removed.reason.refreshSurfaces", defaultValue: "there is nothing to refresh", bundle: .cmuxCLI)
        case "right-sidebar":
            return String(localized: "cli.removed.reason.rightSidebar", defaultValue: "the right sidebar is not part of cmux-next", bundle: .cmuxCLI)
        case "set-app-focus", "simulate-app-active":
            return String(localized: "cli.removed.reason.focusOverrides", defaultValue: "focus overrides were a debug feature of the old app", bundle: .cmuxCLI)
        default:
            return nil
        }
    }

    func removedCommandError(_ command: String) -> CLIError? {
        guard let reason = Self.removedCommandReason(command) else { return nil }
        let format = String(
            localized: "cli.removed.error",
            defaultValue: "unsupported in cmux-next: %1$@ (cmux %2$@)",
            bundle: .cmuxCLI
        )
        return CLIError(message: String(format: format, reason, command))
    }

    func unknownCommandError(_ command: String) -> CLIError {
        let message: String
        if let suggestion = suggestedCommandName(for: command) {
            let format = String(
                localized: "cli.unknownCommand.errorWithSuggestion",
                defaultValue: "Unknown command '%1$@'. Did you mean '%2$@'? Run 'cmux --help' for the full command list.",
                bundle: .cmuxCLI
            )
            message = String(format: format, command, suggestion)
        } else {
            let format = String(
                localized: "cli.unknownCommand.error",
                defaultValue: "Unknown command '%@'. Run 'cmux --help' for the full command list.",
                bundle: .cmuxCLI
            )
            message = String(format: format, command)
        }
        return CLIError(message: message, exitCode: 2)
    }

    private func suggestedCommandName(for command: String) -> String? {
        var bestName: String?
        var bestDistance = Int.max

        for candidate in Self.topLevelCommandNames where !candidate.hasPrefix("__") {
            let distance = editDistance(command, candidate)
            guard distance > 0, distance <= 2, distance < candidate.count else { continue }
            if distance < bestDistance || (distance == bestDistance && candidate < (bestName ?? candidate)) {
                bestName = candidate
                bestDistance = distance
            }
        }

        return bestName
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[rightIndex + 1] = previous[rightIndex]
                } else {
                    current[rightIndex + 1] = min(min(previous[rightIndex + 1], current[rightIndex]), previous[rightIndex]) + 1
                }
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    /// Every top-level command (`CLITopLevelCommands`).
    static var topLevelCommandNames: Set<String> { CLITopLevelCommands.names }
}
