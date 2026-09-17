internal import Foundation

/// Ghostty's parsed `command` configuration, with its launch form fixed at
/// the configuration boundary.
///
/// This parser follows `Command.parseCLI` in
/// `ghostty/src/config/command.zig`. Direct mode splits on each literal space.
/// Quotes have no grouping meaning and repeated spaces create empty arguments.
public struct GhosttyConfiguredCommand: Equatable, Sendable {
    /// The launch form selected by Ghostty's command prefix.
    public let launchForm: TerminalSurfaceLaunchForm

    /// Parses one effective Ghostty `command` value.
    public init?(rawValue: String) {
        // Match Ghostty Command.parseCLI exactly: it trims the full input and
        // the prefixed payload before direct mode splits on literal spaces.
        // Edge spaces are not arguments; repeated interior spaces are.
        let command = rawValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        guard let separator = command.firstIndex(of: ":") else {
            guard let launchForm = TerminalSurfaceLaunchForm(command: command) else {
                return nil
            }
            self.launchForm = launchForm
            return
        }
        let prefix = String(command[..<separator])
        let payload = String(command[command.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        let launchForm: TerminalSurfaceLaunchForm?
        switch prefix {
        case "direct":
            launchForm = TerminalSurfaceLaunchForm(
                arguments: payload.components(separatedBy: " ")
            )
        case "shell":
            launchForm = TerminalSurfaceLaunchForm(command: payload)
        default:
            launchForm = TerminalSurfaceLaunchForm(command: command)
        }
        guard let launchForm else { return nil }
        self.launchForm = launchForm
    }
}
