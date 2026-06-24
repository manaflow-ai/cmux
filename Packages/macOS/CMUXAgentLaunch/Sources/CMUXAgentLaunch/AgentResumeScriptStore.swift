public import Foundation

/// Writes self-deleting `/bin/zsh` launcher scripts for resume/fork startup
/// input, and prunes scripts older than its TTL on every write.
///
/// When a resume/fork startup command is too large to inline as terminal input,
/// the app spills it to a one-shot launcher script under a private
/// `cmux-agent-resume` directory in the temporary directory and feeds the
/// terminal a `/bin/zsh <script>` invocation instead. The script deletes itself
/// (`rm -f -- "$0"`) as its first line, and the store prunes any leftover
/// `.zsh` scripts older than ``scriptTTL`` (24h) so a crash before self-delete
/// cannot accumulate scripts. The directory is created `0700` and each script
/// `0600` so only the current user can read or execute them.
///
/// This is an instance value type with constructor-injected `FileManager` and
/// `temporaryDirectory` so tests can point it at a scratch directory. It is
/// decoupled from the app-side agent domain: callers lower their
/// `RestorableAgentKind` to ``kindRawValue`` for the filename prefix and
/// precompute the return-to-login-shell lines app-side, passing them in via
/// ``returnShellLines`` (the `TerminalStartupReturnShellScript` helper stays
/// app-side).
public struct AgentResumeScriptStore: Sendable {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    private let fileManager: FileManager
    private let temporaryDirectory: URL

    /// Creates a script store writing under `temporaryDirectory` via the given
    /// `fileManager`.
    public init(fileManager: FileManager, temporaryDirectory: URL) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    /// Writes a self-deleting `/bin/zsh` launcher script and returns its URL, or
    /// `nil` if any filesystem step fails.
    ///
    /// - Parameters:
    ///   - command: The agent command the script runs. Used directly as the
    ///     script body when `returnShellLines` is `nil`.
    ///   - kindRawValue: The agent kind's wire identifier, used as the script
    ///     filename prefix (callers lower `RestorableAgentKind.rawValue`).
    ///   - sessionId: The session identifier; its first 12 characters (with
    ///     non-alphanumeric/`-` replaced by `_`) form part of the filename.
    ///   - returnShellLines: Precomputed return-to-login-shell script lines. When
    ///     non-`nil` they replace the bare `command` line so the launched shell
    ///     persists after the command exits; when `nil` the script runs
    ///     `command` directly. The app computes these from
    ///     `TerminalStartupReturnShellScript.commandThenReturnLines`.
    public func writeLauncherScript(
        command: String,
        kindRawValue: String,
        sessionId: String,
        returnShellLines: [String]? = nil
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kindRawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if let returnShellLines {
                lines.append(contentsOf: returnShellLines)
            } else {
                lines.append(command)
            }
            let contents = lines.joined(separator: "\n") + "\n"
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private func pruneOldScripts(in directoryURL: URL) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}
