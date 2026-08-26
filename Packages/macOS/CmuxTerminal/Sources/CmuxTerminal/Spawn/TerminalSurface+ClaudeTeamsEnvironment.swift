import Darwin
import Foundation

/// Startup-environment helpers for Claude Code's tmux-compatible agent teams.
///
/// Claude asks the cmux CLI to create teammate surfaces from a child process,
/// so the tmux shim must remain on the child surface's PATH. The app-managed
/// command-shim directory is assembled before Ghostty starts the shell; these
/// helpers validate the launch-provided shim and add its directory after the
/// app's normal PATH entries have been assembled.
extension TerminalSurface {
    private static let claudeTeamsMarkerKeys = [
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
        "CMUX_CLAUDE_TEAMS_CMUX_BIN",
        "CMUX_CLAUDE_TEAMS_TMUX_SHIM",
    ]

    /// Returns the validated tmux shim path supplied to a Claude Teams surface.
    /// Invalid, non-private, or symlinked paths are ignored so a generic
    /// `surface.create` startup environment cannot redirect unrelated shells.
    static func claudeTeamsTmuxShimPath(
        from environment: [String: String],
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileManager: FileManager = .default
    ) -> String? {
        guard isClaudeTeamsStartupEnvironment(environment),
              let rawPath = environment["CMUX_CLAUDE_TEAMS_TMUX_SHIM"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }

        let shimURL = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        guard shimURL.lastPathComponent == "tmux",
              isExecutableFile(shimURL.path),
              let values = try? shimURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }

        let directory = shimURL.deletingLastPathComponent().standardizedFileURL
        guard isPrivateDirectory(directory, fileManager: fileManager) else { return nil }
        return shimURL.path
    }

    /// Whether the startup environment belongs to a Claude Teams launch.
    private static func isClaudeTeamsStartupEnvironment(_ environment: [String: String]) -> Bool {
        claudeTeamsMarkerKeys.contains { key in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return false
            }
            return true
        }
    }

    private static func isPrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
            return false
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        return permissions & 0o022 == 0
    }
}
