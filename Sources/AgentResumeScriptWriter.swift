import CMUXAgentLaunch
import Foundation

/// Writes (and prunes) the throwaway zsh launcher scripts cmux drops into a
/// per-temporary-directory `cmux-agent-resume` folder when a resume/fork
/// command is too large to type inline as startup input.
///
/// `fileManager` is constructor-injected so callers (and tests) scope every
/// filesystem operation through one handle. Scripts self-delete on first run
/// (`rm -f -- "$0"`) and any sibling older than `scriptTTL` is pruned before a
/// new one is written.
struct AgentResumeScriptWriter {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        temporaryDirectory: URL,
        returnToLoginShell: Bool = false,
        workingDirectory: String? = nil
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
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if returnToLoginShell {
                lines.append(contentsOf: TerminalStartupReturnShellScript().commandThenReturnLines(
                    command: command,
                    workingDirectory: workingDirectory
                ))
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
