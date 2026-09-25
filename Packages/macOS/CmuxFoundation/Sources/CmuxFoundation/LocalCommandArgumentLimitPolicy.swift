internal import Foundation

/// Keeps oversized local shell commands out of a process argument vector.
public struct LocalCommandArgumentLimitPolicy: Sendable {
    /// Maximum UTF-8 bytes for a command kept inline in a process argument.
    ///
    /// The limit leaves headroom for the executable, environment, and other
    /// arguments on macOS, and also stays below Linux's per-argument limit.
    public static let maximumInlineCommandBytes = 120_000

    /// Creates a command-size policy.
    public init() {}

    /// Returns a command suitable for the next process spawn.
    ///
    /// Commands above ``maximumInlineCommandBytes`` are handed to the caller's
    /// file-backed writer. The original command is retained if writing fails,
    /// so callers preserve their existing error path rather than silently
    /// dropping a requested launch.
    ///
    /// - Parameters:
    ///   - command: The shell command that would otherwise be passed inline.
    ///   - workingDirectory: The directory the file-backed launcher should use.
    ///   - writeExternalCommand: Writer that returns a short command invoking its file.
    /// - Returns: The original command for small inputs, or the writer result for large inputs.
    public func commandForSpawn(
        command: String?,
        workingDirectory: String?,
        writeExternalCommand: @Sendable (_ command: String, _ workingDirectory: String?) -> String?
    ) -> String? {
        guard let command,
              command.utf8.count > Self.maximumInlineCommandBytes else {
            return command
        }
        let commandToExternalize = Self.posixShellScript(from: command) ?? command
        return writeExternalCommand(commandToExternalize, workingDirectory) ?? command
    }

    private static func posixShellScript(from command: String) -> String? {
        let prefix = "/bin/sh -c "
        guard command.hasPrefix(prefix) else { return nil }

        let quotedScript = Array(command.dropFirst(prefix.count))
        guard quotedScript.count >= 2,
              quotedScript.first == "'",
              quotedScript.last == "'" else {
            return nil
        }

        var script = ""
        var index = 1
        while index < quotedScript.count - 1 {
            if quotedScript[index] == "'" {
                guard index + 3 < quotedScript.count,
                      quotedScript[index + 1] == "\\",
                      quotedScript[index + 2] == "'",
                      quotedScript[index + 3] == "'" else {
                    return nil
                }
                script.append("'")
                index += 4
            } else {
                script.append(quotedScript[index])
                index += 1
            }
        }
        return script
    }
}
